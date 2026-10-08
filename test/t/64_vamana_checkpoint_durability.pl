# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 64_vamana_checkpoint_durability.pl — durability of the checkpoint save
# sequence for a vamana index.
#
# A checkpoint writes the SVS graph and the sidecar TID map into
# $PGDATA/vamana_indexes/<dboid>/<relid>/, then advances the replication slot.  The TID
# map is written to tidmap.bin.tmp and moved onto tidmap.bin with
# durable_rename (vamanaio.c, VamanaSaveTidMapAtomically), which fsyncs the
# temporary file, the renamed file and the containing directory before
# returning.  The loader (VamanaLoadTidMap) validates a magic/version/capacity
# header and returns false on anything it does not recognize, which makes the
# worker fall back to a full rebuild from the heap.
#
# Together those two properties are what makes a crash anywhere in the save
# sequence safe: the live file is only ever replaced by a complete one, and a
# file that is missing or does not validate costs a rebuild rather than wrong
# answers.  The tests below exercise both halves.
#
# Tests:
#   Completed checkpoint survives an immediate crash: tidmap.bin is
#       byte-identical after restart, the loader accepts it, and search
#       results are unchanged.
#   A leftover tidmap.bin.tmp is never a load source, and does not wedge the
#       next checkpoint, which consumes it.
#   Self-healing: a truncated tidmap.bin and an absent tidmap.bin each fall
#       back to a heap rebuild and still answer every row.
#   Repeated crashes with no wait for the checkpoint to finish never leave a
#       tidmap.bin that fails the header/size invariant.
#
# What this file cannot show.  A crash injected between the rename and the
# directory fsync is not reachable here: those two steps are both inside core
# PostgreSQL's durable_rename, and this build has no injection points
# (enable_injection_points is not 'yes'), so there is no way to park a process
# between them.  Nor can stop('immediate') observe a missing fsync at all: it
# kills the postmaster but leaves the kernel page cache intact, so an unsynced
# rename is still visible afterwards.  Only host-level power loss distinguishes
# rename(2) from durable_rename.  What the tests do cover is that the call
# succeeds for this path shape (with fsync = on, so the fsyncs really run) and
# that every on-disk state the save sequence can leave behind recovers.
#
# Layout: each test owns its own cluster inside its own block and stops it at
# the end, so the helpers above are the only shared state.  Add a new test as
# another block before done_testing().

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# On-disk layout of the sidecar TID map, from VamanaTidMapHeader in
# src/vamanaio.c: four uint32 fields followed by one 6-byte ItemPointerData
# per slot.  A file of any other size for its declared capacity is torn.
my $TIDMAP_MAGIC       = 0x53565354;    # "SVST"
my $TIDMAP_VERSION     = 1;
my $TIDMAP_HEADER_SIZE = 16;
my $TIDMAP_SLOT_SIZE   = 6;

# ---------------------------------------------------------------------------
# start_durability_node: cluster with the background worker enabled and fsync
# on.  TAP clusters default to fsync = off, which turns every fsync in the
# checkpoint save path into a no-op and would leave the code under test
# unexercised.
# ---------------------------------------------------------------------------
sub start_durability_node
{
    my ($name, @extra_conf) = @_;

    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->append_conf('postgresql.conf', "fsync = on");
    # Every scan here runs right after a restart, when the worker is also
    # loading or rebuilding the index.  The 5 s default leaves no headroom for
    # that on a busy host, and a scan that gives up looks like a lost row.
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
    $node->append_conf('postgresql.conf', $_) for @extra_conf;
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    return $node;
}

# ---------------------------------------------------------------------------
# wait_for_slot_consistent: block until this database's vamana replication
# slot reaches its initial CONSISTENT point.  A disk-load after a crash that
# lands before this point forces a heap rebuild regardless of what is on disk
# (see VamanaWorkerGetOrLoadIndex's post-load consistency check), so tests
# that assert a crash preserves the checkpoint instead of triggering a
# rebuild must crash only after this returns true.
# ---------------------------------------------------------------------------
sub wait_for_slot_consistent
{
    my ($node) = @_;

    for (1 .. 200)    # up to 20s
    {
        my $v = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn FROM pg_replication_slots
            WHERE slot_name LIKE 'vamana_%';
        });
        chomp $v;
        return 1 if $v ne '';
        usleep(100_000);
    }
    return 0;
}

# ---------------------------------------------------------------------------
# tidmap_path: on-disk sidecar path for the named index relation.
# ---------------------------------------------------------------------------
sub tidmap_path
{
    my ($node, $relname) = @_;

    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = '$relname';");
    chomp $ioid;
    die "no oid for relation $relname" unless $ioid =~ /^\d+$/;

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = current_database();");
    chomp $dboid;
    die "no oid for current database" unless $dboid =~ /^\d+$/;

    return $node->data_dir . "/vamana_indexes/$dboid/$ioid/tidmap.bin";
}

# ---------------------------------------------------------------------------
# slurp_raw / read_tidmap_header: raw file access for the on-disk assertions.
# ---------------------------------------------------------------------------
sub slurp_raw
{
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or die "open $path: $!";
    my $data = do { local $/; <$fh> };
    close($fh);
    return $data;
}

sub read_tidmap_header
{
    my ($path) = @_;

    my $data = slurp_raw($path);
    return undef unless defined $data && length($data) >= $TIDMAP_HEADER_SIZE;

    my ($magic, $version, $capacity, $reserved) =
      unpack('L4', substr($data, 0, $TIDMAP_HEADER_SIZE));

    return {
        magic    => $magic,
        version  => $version,
        capacity => $capacity,
        reserved => $reserved,
        size     => length($data),
    };
}

# ---------------------------------------------------------------------------
# tidmap_defect: '' when the file satisfies everything the writer guarantees,
# otherwise a description of the first violation.  Returns a defect for a
# missing file, so callers that tolerate absence must check -f first.
# ---------------------------------------------------------------------------
sub tidmap_defect
{
    my ($path) = @_;

    return 'file absent' unless -f $path;

    my $h = read_tidmap_header($path);
    return 'shorter than the header' unless defined $h;
    return sprintf('bad magic 0x%08X', $h->{magic})
      unless $h->{magic} == $TIDMAP_MAGIC;
    return "bad version $h->{version}"
      unless $h->{version} == $TIDMAP_VERSION;

    my $want = $TIDMAP_HEADER_SIZE + $h->{capacity} * $TIDMAP_SLOT_SIZE;
    return "size $h->{size} does not match capacity $h->{capacity} (want $want)"
      unless $h->{size} == $want;

    return '';
}

# ---------------------------------------------------------------------------
# wait_for_tidmap: poll until the sidecar file appears (or changes, when a
# previous copy is supplied).  Returns the file contents, or undef on timeout.
# ---------------------------------------------------------------------------
sub wait_for_tidmap
{
    my ($path, $previous, $attempts) = @_;
    $attempts //= 40;

    for (1 .. $attempts)
    {
        my $data = slurp_raw($path);
        if (defined $data && (!defined $previous || $data ne $previous))
        {
            # Guard against reading a file the writer has not finished with.
            return $data if tidmap_defect($path) eq '';
        }
        usleep(500_000);
    }
    return undef;
}

# ---------------------------------------------------------------------------
# wait_for_index_count: poll the index scan until it returns $want distinct
# rows.  Replay after a crash is asynchronous; polling keeps a slow replay
# from looking like a wrong answer, and a genuinely wrong answer still fails
# once the attempts run out.
# ---------------------------------------------------------------------------
sub wait_for_index_count
{
    my ($node, $sql, $want, $attempts) = @_;
    $attempts //= 40;

    my $got = '';
    for (1 .. $attempts)
    {
        $got = $node->safe_psql('postgres', $sql);
        chomp $got;
        return $got if $got eq "$want";
        usleep(500_000);
    }
    return $got;
}

# ===========================================================================
# A completed checkpoint survives an immediate crash
#
# The last insert triggers a checkpoint (min_ops = 1), so the save sequence has
# run to completion before the crash.  After restart the sidecar must be the
# same complete file, the loader must accept it rather than rejecting and
# rebuilding, and search results must be unchanged.
# ===========================================================================
{
    my $node = start_durability_node('vamana_ckpt_crash',
        "svs.checkpoint_min_ops = 1",
        "svs.checkpoint_debounce_window = 1");

    $node->safe_psql('postgres', qq{
        CREATE TABLE ck_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO ck_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX ck_idx ON ck_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    # Reach slot consistency before the triggering insert below, not after:
    # waiting afterward would leave a window in which a background capacity
    # grow could run its own checkpoint and change tidmap.bin out from under
    # $before, between the baseline capture and the crash.
    ok(wait_for_slot_consistent($node),
        'replication slot reaches consistency before the triggering insert');

    # confirmed_flush only reaches disk at a PostgreSQL checkpoint; an
    # immediate crash loses any in-memory-only advance since the slot's last
    # on-disk save, which would make the slot look inconsistent again after
    # restart and force a heap rebuild despite the wait above.
    $node->safe_psql('postgres', 'CHECKPOINT;');

    # The save path's fsyncs are no-ops when fsync is off, so a cluster that
    # lost this setting would leave the code under test unexercised.
    is($node->safe_psql('postgres', 'SHOW fsync;'), 'on',
        'cluster runs with fsync enabled');

    my $tidmap = tidmap_path($node, 'ck_idx');

    $node->safe_psql('postgres',
        "INSERT INTO ck_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    my $before = wait_for_tidmap($tidmap);
    ok(defined $before, 'checkpoint wrote tidmap.bin with fsync enabled');

    is(tidmap_defect($tidmap), '',
        'tidmap.bin header and size are self-consistent before the crash');

    my $search_sql = qq{
        SET enable_seqscan = off;
        SELECT count(DISTINCT id) FROM (
            SELECT id FROM ck_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
        ) s;
    };
    my $baseline = $node->safe_psql('postgres', $search_sql);
    chomp $baseline;
    is($baseline, 51, 'all 51 rows searchable before the crash');

    my $log_pos = length($node->log_content());
    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    my $after = slurp_raw($tidmap);
    ok(defined $after, 'tidmap.bin still present after crash recovery');
    is(tidmap_defect($tidmap), '',
        'tidmap.bin is not torn after crash recovery');
    ok(defined $after && defined $before && $after eq $before,
        'tidmap.bin is byte-identical to the pre-crash checkpoint');

    is(wait_for_index_count($node, $search_sql, 51), 51,
        'all 51 rows searchable after crash recovery');

    # Sampled after the search: a rebuild can be triggered lazily by the first
    # scan, so a slice taken before it would miss one.
    #
    # Whether this reload replays from the slot or falls back to a heap
    # rebuild is governed by replication-slot consistency (see
    # VamanaReplicationSlotIsConsistent and test/t/45-49), not by anything
    # durable_rename affects.  Both outcomes read the same tidmap.bin this
    # block already checked above, so only the load itself is asserted here.
    my $log = substr($node->log_content(), $log_pos);
    unlike($log, qr/TID map (?:is malformed|is truncated)/,
        'loader did not reject the persisted TID map after the crash');
    unlike($log, qr/TID map missing or corrupt/,
        'loader accepted the persisted TID map after the crash');

    $node->stop;
}

# ===========================================================================
# A leftover temporary file is inert
#
# A crash between opening tidmap.bin.tmp and the rename leaves a partial
# temporary file next to a complete tidmap.bin.  Because the writer only ever
# publishes through the rename, the leftover must not be read on load, and the
# next checkpoint must consume it rather than fail on it.
# ===========================================================================
{
    my $node = start_durability_node('vamana_ckpt_tmpfile',
        "svs.checkpoint_min_ops = 1",
        "svs.checkpoint_debounce_window = 1");

    $node->safe_psql('postgres', qq{
        CREATE TABLE tmp_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO tmp_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX tmp_idx ON tmp_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $tidmap = tidmap_path($node, 'tmp_idx');
    my $tmpfile = "$tidmap.tmp";

    $node->safe_psql('postgres',
        "INSERT INTO tmp_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    my $good = wait_for_tidmap($tidmap);
    ok(defined $good, 'checkpoint wrote tidmap.bin');

    my $search_sql = qq{
        SET enable_seqscan = off;
        SELECT count(DISTINCT id) FROM (
            SELECT id FROM tmp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
        ) s;
    };

    $node->stop;
    ok(!-f $tmpfile,
        'a completed save leaves no temporary file behind');

    # Stand in for a crash partway through writing the temporary file: a valid
    # header followed by fewer slots than it claims.
    open(my $fh, '>:raw', $tmpfile) or die "open $tmpfile: $!";
    print $fh pack('L4', $TIDMAP_MAGIC, $TIDMAP_VERSION, 51, 0);
    print $fh "\x00" x $TIDMAP_SLOT_SIZE;
    close($fh);

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    # Not necessarily byte-identical to $good: a load can grow tidMapCapacity
    # to reconcile against the metapage independently of the stale temp file,
    # which is a correctness-preserving housekeeping step, not evidence the
    # loader read the .tmp file.  What the stale .tmp file must not do is make
    # the load reject tidmap.bin or desync it from the heap.
    is(tidmap_defect($tidmap), '',
        'tidmap.bin remains valid after restart with a stale temporary file present');
    is(wait_for_index_count($node, $search_sql, 51), 51,
        'all 51 rows searchable with a stale temporary file present');

    my $log = substr($node->log_content(), $log_pos);
    unlike($log, qr/TID map (?:is malformed|is truncated)/,
        'stale temporary file is not read on load');
    unlike($log, qr/TID map missing or corrupt/,
        'stale temporary file does not make the loader reject tidmap.bin');
    unlike($log, qr/rebuilding vamana index from table data/,
        'stale temporary file does not force a rebuild');

    # The next checkpoint must publish through the same temporary path.
    $node->safe_psql('postgres',
        "INSERT INTO tmp_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    my $rewritten = wait_for_tidmap($tidmap, $good);
    ok(defined $rewritten,
        'next checkpoint rewrote tidmap.bin despite the stale temporary file');
    is(tidmap_defect($tidmap), '',
        'rewritten tidmap.bin header and size are self-consistent');

    # wait_for_tidmap above can observe tidmap.bin's content change as soon as
    # the content differs from $good, which a capacity-growth reconciliation
    # save can do independently of (and slightly ahead of) the checkpoint
    # that this INSERT triggers.  Poll rather than check once, so a checkpoint
    # still mid-rename at that exact instant is not mistaken for one that
    # never consumed the temp file.
    my $tmp_consumed = 0;
    for (1 .. 20)
    {
        if (!-f $tmpfile)
        {
            $tmp_consumed = 1;
            last;
        }
        usleep(250_000);
    }
    ok($tmp_consumed, 'the rename consumed the temporary file');

    $node->stop;
}

# ===========================================================================
# Self-healing when the sidecar is unusable
#
# Two on-disk states a crash can leave: a torn file (a rename that never
# happened, or a file the kernel wrote only part of), and no file at all (the
# directory entry lost because the rename was not durable — the state
# durable_rename exists to prevent).  Both must cost a rebuild from the heap,
# never a wrong answer.  The two take different branches in VamanaLoadTidMap:
# a short read is reported, ENOENT is the silent "no saved file" signal.
# ===========================================================================
{
    my $node = start_durability_node('vamana_ckpt_selfheal',
        "svs.checkpoint_min_ops = 1",
        "svs.checkpoint_debounce_window = 1");

    $node->safe_psql('postgres', qq{
        CREATE TABLE heal_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO heal_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX heal_idx ON heal_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $tidmap = tidmap_path($node, 'heal_idx');

    $node->safe_psql('postgres',
        "INSERT INTO heal_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    ok(defined wait_for_tidmap($tidmap), 'checkpoint wrote tidmap.bin');

    my $search_sql = qq{
        SET enable_seqscan = off;
        SELECT count(DISTINCT id) FROM (
            SELECT id FROM heal_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
        ) s;
    };

    # Torn file: keep the header, drop all but two slots.
    $node->stop;
    my $header = read_tidmap_header($tidmap);
    ok($header && $header->{capacity} > 2,
        'persisted TID map declares more than two slots');
    truncate($tidmap, $TIDMAP_HEADER_SIZE + 2 * $TIDMAP_SLOT_SIZE)
      or die "truncate $tidmap: $!";

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    is(wait_for_index_count($node, $search_sql, 51), 51,
        'all 51 rows searchable after the truncated map was rejected');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/TID map is truncated/,
        'truncated tidmap.bin rejected on load');
    like($log, qr/TID map missing or corrupt, rebuilding/,
        'loader chose a rebuild over the truncated map');
    like($log, qr/rebuilding vamana index from table data/,
        'index rebuilt from the heap after rejecting the truncated map');

    # Lost directory entry: no sidecar at all, with the graph still on disk.
    $node->stop;
    unlink($tidmap) if -f $tidmap;
    unlink("$tidmap.tmp") if -f "$tidmap.tmp";
    ok(!-f $tidmap, 'tidmap.bin removed to stand in for a lost rename');

    $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    is(wait_for_index_count($node, $search_sql, 51), 51,
        'all 51 rows searchable after rebuilding from an absent map');

    $log = substr($node->log_content(), $log_pos);
    unlike($log, qr/TID map (?:is malformed|is truncated)/,
        'an absent TID map is not reported as malformed');
    like($log, qr/TID map missing or corrupt, rebuilding/,
        'loader chose a rebuild when the TID map is absent');
    like($log, qr/rebuilding vamana index from table data/,
        'index rebuilt from the heap when the TID map is absent');

    $node->stop;
}

# ===========================================================================
# Repeated crashes with no wait for the save to finish
#
# The crash point is not controllable from here, so this asserts the invariants
# that hold at every point in the save sequence rather than one outcome:
# tidmap.bin is either absent or a complete file whose header and size agree,
# and the reloaded index answers without duplicate TIDs and without claiming
# rows the heap does not have.  A publish that was not atomic would eventually
# be caught as a header/size mismatch, which is the state the
# write-to-temp-then-rename design excludes.
#
# How complete the row set is after an uncontrolled crash is deliberately not
# asserted here: that depends on how far slot replay has got, which is a
# property of the replay path rather than of the save sequence, and the
# replication-slot suite already covers the settled case.
# ===========================================================================
{
    my $node = start_durability_node('vamana_ckpt_crashloop',
        "svs.checkpoint_min_ops = 1",
        "svs.checkpoint_debounce_window = 1");

    # Row counts stay under the default search window (100 candidates), so the
    # counts below reflect what the index holds rather than where the graph
    # search stopped looking.
    $node->safe_psql('postgres', qq{
        CREATE TABLE loop_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO loop_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX loop_idx ON loop_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $tidmap = tidmap_path($node, 'loop_idx');
    my $rows = 50;

    for my $round (1 .. 3)
    {
        # Insert, then crash without waiting: the checkpoint the insert
        # triggers may be at any stage when the postmaster dies.
        $node->safe_psql('postgres', qq{
            INSERT INTO loop_tbl (val)
                SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
        });
        $rows += 5;
        $node->stop('immediate');

        my $defect = (-f $tidmap) ? tidmap_defect($tidmap) : '';
        is($defect, '',
            "round $round: tidmap.bin is absent or complete after the crash");

        $node->start;
        wait_for_worker($node, 30);

        # A reloaded index that returns a TID twice, or a row the heap does not
        # have, is the observable form of a corrupt TID map.
        my $counts = $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT count(*), count(DISTINCT id) FROM (
                SELECT id FROM loop_tbl ORDER BY val <-> '[$query_sql]'
                LIMIT 100000
            ) s;
        });
        chomp $counts;
        my ($total, $distinct) = split(/\|/, $counts);

        is($total, $distinct,
            "round $round: no duplicate TIDs from the reloaded index");
        ok($distinct > 0 && $distinct <= $rows,
            "round $round: index returned $distinct of at most $rows rows");
    }

    $node->stop;
}

done_testing();
