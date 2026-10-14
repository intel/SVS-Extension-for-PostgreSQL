# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 68_vamana_metapage_format_upgrade.pl: an index built with an older
# on-disk metapage format must fail closed, with no worker crash, and
# REINDEX must restore service.
# Covers: VamanaReadMetaPage magic-number check (src/vamanautils.c)

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# The current magic number (src/vamana.h) and the value it replaced in the
# commit that grew VamanaMetaPageData. Little-endian uint32, offset 0 of the
# metapage contents (byte offset 24 of the page: a 24-byte MAXALIGN'd page
# header, then the metapage struct).
my $CURRENT_MAGIC = 0xA954A955;
my $OLD_MAGIC      = 0xA954A954;
my $MAGIC_OFFSET   = 24;

sub patch_magic
{
    my ($file, $expect, $write) = @_;
    open(my $fh, '+<:raw', $file) or die "open $file: $!";
    seek($fh, $MAGIC_OFFSET, 0) or die "seek $file: $!";
    my $have;
    read($fh, $have, 4) or die "read $file: $!";
    is($have, pack('V', $expect),
        "metapage magic at offset $MAGIC_OFFSET is " . sprintf('0x%08X', $expect)
      . " before patch");
    seek($fh, $MAGIC_OFFSET, 0) or die "seek $file: $!";
    print $fh pack('V', $write);
    close($fh);
}

# PG 18 initdb enables data checksums by default; a raw byte edit on a
# checksummed page fails with a checksum error before the magic check in
# VamanaReadMetaPage ever runs, which would pass this test for the wrong
# reason.
my $node = PostgreSQL::Test::Cluster->new('vamana_format_upgrade');
$node->init(no_data_checksums => 1);
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$node->safe_psql('postgres', qq{
    CREATE TABLE fmt_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO fmt_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX fmt_idx ON fmt_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker($node, 30);

# One search to make sure the index is built, saved, and warm before the
# node stops.
$node->safe_psql('postgres', qq{
    SET enable_seqscan = off;
    SELECT id FROM fmt_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
});

my $relfile = $node->safe_psql('postgres',
    "SELECT pg_relation_filepath('fmt_idx');");
chomp $relfile;
my $idx_file = $node->data_dir . "/$relfile";

$node->stop;
ok(-f $idx_file, 'index main-fork file exists after clean stop');
patch_magic($idx_file, $CURRENT_MAGIC, $OLD_MAGIC);

$node->start;
my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, 'worker running after restart with stale metapage');

my $format_err_re  = qr/was built with an incompatible on-disk format/;
my $reindex_hint_re = qr/REINDEX this index\./;

# --- INSERT: backend reads the metapage itself before submitting to the worker ---
{
    my ($ret, $out, $err) = $node->psql('postgres',
        "INSERT INTO fmt_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    isnt($ret, 0, 'INSERT into a stale-format index fails');
    like($err, $format_err_re, 'INSERT reports the incompatible-format error');
    like($err, $reindex_hint_re, 'INSERT carries the REINDEX hint');
}

# --- VACUUM: ambulkdelete reads the metapage itself ---
{
    $node->safe_psql('postgres', "DELETE FROM fmt_tbl WHERE id = 1;");
    my ($ret, $out, $err) = $node->psql('postgres', "VACUUM fmt_tbl;");
    isnt($ret, 0, 'VACUUM on a table with a stale-format index fails');
    like($err, $format_err_re, 'VACUUM reports the incompatible-format error');
    like($err, $reindex_hint_re, 'VACUUM carries the REINDEX hint');
}

# --- SELECT: served by the worker; what the client and the log actually
# show is the open question this test exists to settle. Record both.
{
    my $log_pos = length($node->log_content());
    my ($ret, $out, $err) = $node->psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM fmt_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    my $log = substr($node->log_content(), $log_pos);
    isnt($ret, 0, 'SELECT against a stale-format index fails');
    like($err, $format_err_re, 'SELECT reports the incompatible-format error to the client');
    like($err, $reindex_hint_re, 'SELECT carries the REINDEX hint to the client');
    like($log, $format_err_re, 'the incompatible-format detail also reaches the server log');

    my (undef, undef, $sqlstate_err) = $node->psql('postgres', qq{
        SET enable_seqscan = off;
        DO \$do\$
        BEGIN
            PERFORM id FROM fmt_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'sqlstate=%', SQLSTATE;
        END
        \$do\$;
    });
    like($sqlstate_err, qr/sqlstate=22000/,
        'SELECT raises a data-exception SQLSTATE, not an internal-error one');
}

# --- No crash: worker pid unchanged, no fatal lines in the log since restart ---
{
    my $pid_now = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker' LIMIT 1;");
    chomp $pid_now;
    is($pid_now, $worker_pid, 'worker pid unchanged after INSERT/VACUUM/SELECT against stale index');

    my $log = $node->log_content();
    unlike($log, qr/terminated by signal|was terminated|all server processes terminated/,
        'no worker or postmaster crash in the log');
}

# --- REINDEX restores service ---
{
    $node->safe_psql('postgres', "REINDEX INDEX fmt_idx;");
    my $search_out = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM fmt_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    isnt($search_out, '', 'SELECT works after REINDEX');

    $node->safe_psql('postgres',
        "INSERT INTO fmt_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    pass('INSERT works after REINDEX');

    $node->safe_psql('postgres', "VACUUM fmt_tbl;");
    pass('VACUUM works after REINDEX');
}

# --- REINDEX INDEX CONCURRENTLY on a freshly re-patched stale index ---
{
    $node->safe_psql('postgres', qq{
        CREATE TABLE fmt_tbl2 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO fmt_tbl2 (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX fmt_idx2 ON fmt_tbl2 USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM fmt_tbl2 ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });

    my $relfile2 = $node->safe_psql('postgres',
        "SELECT pg_relation_filepath('fmt_idx2');");
    chomp $relfile2;
    my $idx_file2 = $node->data_dir . "/$relfile2";

    $node->stop;
    patch_magic($idx_file2, $CURRENT_MAGIC, $OLD_MAGIC);
    $node->start;
    wait_for_worker($node, 30);

    my ($ret, $out, $err) = $node->psql('postgres',
        "REINDEX INDEX CONCURRENTLY fmt_idx2;");
    note("REINDEX CONCURRENTLY on a stale index: ret=$ret err=$err");
    if ($ret == 0)
    {
        pass('REINDEX INDEX CONCURRENTLY succeeds on a stale-format index');
        my $search_out2 = $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT id FROM fmt_tbl2 ORDER BY val <-> '[$query_sql]' LIMIT 5;
        });
        isnt($search_out2, '', 'SELECT works after REINDEX CONCURRENTLY');
    }
    else
    {
        fail('REINDEX INDEX CONCURRENTLY on a stale-format index (see log for diag)');
        diag("REINDEX CONCURRENTLY stderr: $err");
    }
}

# --- DROP INDEX works on a stale-format index without needing the metapage ---
{
    $node->safe_psql('postgres', qq{
        CREATE TABLE fmt_tbl3 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO fmt_tbl3 (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX fmt_idx3 ON fmt_tbl3 USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM fmt_tbl3 ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });

    my $ioid3 = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'fmt_idx3';");
    chomp $ioid3;
    my $save_dir3 = vamana_save_dir($node, 'postgres', $ioid3);

    my $relfile3 = $node->safe_psql('postgres',
        "SELECT pg_relation_filepath('fmt_idx3');");
    chomp $relfile3;
    my $idx_file3 = $node->data_dir . "/$relfile3";

    $node->stop;
    patch_magic($idx_file3, $CURRENT_MAGIC, $OLD_MAGIC);
    $node->start;
    wait_for_worker($node, 30);

    $node->safe_psql('postgres', "DROP INDEX fmt_idx3;");
    pass('DROP INDEX succeeds on a stale-format index');
    ok(!-d $save_dir3, 'save directory removed after DROP INDEX on a stale-format index');
}

$node->stop;
done_testing();
