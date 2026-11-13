# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 67_vamana_metapage_field_validation.pl -- VamanaReadMetaPage range-checks
# every build-config field it reads, not just the magic number. Each case
# below writes an out-of-range (or in-range but wrong) value directly into
# an index's on-disk metapage and confirms the backend path raises
# ERRCODE_DATA_CORRUPTED naming the field, the worker survives a load
# attempt through the same corrupted field, and REINDEX recovers the index.
#
# The compression-related cases poke compression_type/primary/secondary
# onto an otherwise plain, uncompressed index rather than building a real
# LVQ/LeanVec index first. ValidateMetaPageConfig reads only the metapage
# bytes and runs before any SVS load, so this exercises the same validation
# branch without depending on LVQ/LeanVec hardware support, which not every
# CI runner's CPU has (see HW_TAP_TESTS in the Makefile).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Byte offsets into VamanaMetaPageData, pinned by StaticAssertDecl in
# src/vamana.h. 24 is MAXALIGN(SizeOfPageHeaderData), where PageGetContents
# begins; the metapage is always block 0.
my $PAGE_HEADER_SIZE   = 24;
my %FIELD_OFFSET = (
    dimensions           => 4,
    graph_degree         => 8,
    alpha                => 10,
    compression_type     => 12,
    compression_primary  => 13,
    compression_secondary => 14,
    leanvec_dims         => 16,
    build_window_size    => 20,
);
my %FIELD_PACK = (
    dimensions           => 'V',
    graph_degree         => 'v',
    alpha                => 's<',
    compression_type     => 'C',
    compression_primary  => 'c',
    compression_secondary => 'c',
    leanvec_dims         => 'l<',
    build_window_size    => 'l<',
);

sub poke_metapage_field
{
    my ($path, $field, $value) = @_;
    my $offset = $PAGE_HEADER_SIZE + $FIELD_OFFSET{$field};
    my $packed = pack($FIELD_PACK{$field}, $value);

    open(my $fh, '+<:raw', $path) or die "open $path: $!";
    seek($fh, $offset, 0) or die "seek $path: $!";
    print $fh $packed;
    close($fh);
}

my $node = PostgreSQL::Test::Cluster->new('vamana_metapage_validation');
$node->init(no_data_checksums => 1);    # a checksummed page would fail page
                                         # verification (also XX001) before
                                         # the field check ever ran, and the
                                         # test would pass for the wrong reason
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 20");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, "worker running before any corruption (pid=$worker_pid)");

# ===========================================================================
# Build every table/index up front, then stop once to poke every metapage.
# ===========================================================================
my @cases = (
    {
        name    => 'dim_mismatch',
        pokes   => [ [ 'dimensions', $dim / 2 ] ],
        pattern => qr/metapage dimensions value that does not match its column/,
    },
    {
        name    => 'graph_degree',
        pokes   => [ [ 'graph_degree', 300 ] ],
        pattern => qr/graph_degree value 300 is out of range/,
    },
    {
        name    => 'graph_degree_below_min',
        pokes   => [ [ 'graph_degree', 15 ] ],
        pattern => qr/graph_degree value 15 is out of range/,
    },
    {
        name    => 'alpha',
        pokes   => [ [ 'alpha', -5 ] ],
        pattern => qr/alpha value -5 is out of range/,
    },
    {
        name    => 'alpha_below_min',
        pokes   => [ [ 'alpha', -2 ] ],
        pattern => qr/alpha value -2 is out of range/,
    },
    {
        name    => 'build_window_size',
        pokes   => [ [ 'build_window_size', 2000 ] ],
        pattern => qr/build_window_size value 2000 is out of range/,
    },
    {
        name    => 'build_window_below_min',
        pokes   => [ [ 'build_window_size', -2 ] ],
        pattern => qr/build_window_size value -2 is out of range/,
    },
    {
        name    => 'leanvec_dims',
        pokes   => [ [ 'leanvec_dims', 5000 ] ],
        pattern => qr/leanvec_dims value 5000 is out of range/,
    },
    {
        name    => 'leanvec_dims_below_min',
        pokes   => [ [ 'leanvec_dims', -2 ] ],
        pattern => qr/leanvec_dims value -2 is out of range/,
    },
    {
        name    => 'compression_type',
        pokes   => [ [ 'compression_type', 3 ] ],
        pattern => qr/invalid compression configuration/,
    },
    {
        name    => 'lvq_bad_primary',
        pokes   => [ [ 'compression_type', 2 ], [ 'compression_primary', 5 ], [ 'compression_secondary', 0 ] ],
        pattern => qr/invalid compression configuration/,
    },
    {
        name    => 'lvq_bad_pair',
        pokes   => [ [ 'compression_type', 2 ], [ 'compression_primary', 8 ], [ 'compression_secondary', 8 ] ],
        pattern => qr/invalid compression configuration/,
    },
    {
        name    => 'leanvec_bad_pair',
        pokes   => [ [ 'compression_type', 1 ], [ 'compression_primary', 8 ], [ 'compression_secondary', 4 ] ],
        pattern => qr/invalid compression configuration/,
    },
);

# Boundary cases: the min and max values CheckMetaField accepts must not be
# mistaken for out of range (an off by one error in the bounds would reject
# a legitimate index). These are expected to build and scan cleanly, unlike
# every case above.
my @boundary_valid_cases = (
    { name => 'graph_degree_min', pokes => [ [ 'graph_degree', 16 ] ] },
    { name => 'graph_degree_max', pokes => [ [ 'graph_degree', 256 ] ] },
    { name => 'alpha_min', pokes => [ [ 'alpha', -1 ] ] },
    { name => 'alpha_max', pokes => [ [ 'alpha', 200 ] ] },
    { name => 'build_window_min', pokes => [ [ 'build_window_size', -1 ] ] },
    { name => 'build_window_max', pokes => [ [ 'build_window_size', 1000 ] ] },
    { name => 'leanvec_dims_min', pokes => [ [ 'leanvec_dims', -1 ] ] },
    { name => 'leanvec_dims_max', pokes => [ [ 'leanvec_dims', 2000 ] ] },
);

sub create_case_objects
{
    for my $case (@cases, @boundary_valid_cases)
    {
        my $tbl = "mp_$case->{name}_tbl";
        my $idx = "mp_$case->{name}_idx";
        $node->safe_psql('postgres', qq{
            CREATE TABLE $tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO $tbl (val)
                SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
            CREATE INDEX $idx ON $tbl USING vamana (val vector_l2_ops);
        });
        $case->{table} = $tbl;
        $case->{index} = $idx;
    }

    $node->safe_psql('postgres', qq{
        CREATE TABLE mp_control_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO mp_control_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX mp_control_idx ON mp_control_tbl USING vamana (val vector_l2_ops);
    });

    for my $case (@cases, @boundary_valid_cases)
    {
        my $relpath = $node->safe_psql('postgres',
            "SELECT pg_relation_filepath('$case->{index}');");
        chomp $relpath;
        $case->{path} = $node->data_dir . "/" . $relpath;
    }
}

# A setup failure here (e.g. an unexpected CREATE INDEX error) must not take
# down the whole TAP file with no plan declared: report it as a normal test
# failure with the server log attached instead.
if (!eval { create_case_objects(); 1 })
{
    my $err = $@;
    fail('build every case table/index before corruption');
    diag("setup failed: $err");
    diag("server log tail:\n" . substr($node->log_content(), -4000));
    $node->stop('immediate');
    done_testing();
    exit;
}

$node->stop;

for my $case (@cases, @boundary_valid_cases)
{
    for my $poke (@{ $case->{pokes} })
    {
        poke_metapage_field($case->{path}, $poke->[0], $poke->[1]);
    }
}

$node->start;
$worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, "worker running after restart with corrupted metapages (pid=$worker_pid)");

# ===========================================================================
# Backend path: INSERT must fail with ERRCODE_DATA_CORRUPTED, naming the
# field, with the REINDEX hint, for every corrupted index.
# ===========================================================================
for my $case (@cases)
{
    my $bg = $node->background_psql('postgres', on_error_stop => 0);
    $bg->query_safe("\\set VERBOSITY verbose");
    $bg->query("INSERT INTO $case->{table} (val) VALUES (ARRAY[$array_sql]::vector);");
    my $err = $bg->{stderr} // '';
    like($err, qr/XX001/, "$case->{name}: INSERT fails with XX001");
    like($err, $case->{pattern}, "$case->{name}: INSERT error names the bad field/config");
    like($err, qr/REINDEX this index\./, "$case->{name}: INSERT error carries the REINDEX hint");
    $bg->quit;
}

# ===========================================================================
# Boundary values: the min and max values each range check accepts must not
# be rejected. INSERT and a scan must both succeed on these.
# ===========================================================================
for my $case (@boundary_valid_cases)
{
    $node->safe_psql('postgres',
        "INSERT INTO $case->{table} (val) VALUES (ARRAY[$array_sql]::vector);");
    my $out = $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM $case->{table} ORDER BY val <-> '[$query_sql]' LIMIT 100
        ) s;
    ));
    chomp $out;
    is($out, '51', "$case->{name}: boundary value is accepted, INSERT and scan both succeed");
}

# ===========================================================================
# VACUUM goes through the same backend-side metapage read and must fail the
# same way.
# ===========================================================================
{
    my $case = $cases[0];
    my $bg = $node->background_psql('postgres', on_error_stop => 0);
    $bg->query_safe("\\set VERBOSITY verbose");
    $bg->query("VACUUM $case->{table};");
    my $err = $bg->{stderr} // '';
    like($err, qr/XX001/, "$case->{name}: VACUUM fails with XX001");
    like($err, $case->{pattern}, "$case->{name}: VACUUM error names the bad field");
    $bg->quit;
}

# ===========================================================================
# Worker path: a scan cannot see XX001 (it only reaches the client on a
# backend-side reader), but it must fail cleanly rather than crash the
# worker, and the server log must carry the same field-specific detail.
# Checked on a representative subset; INSERT above already covers every
# field's message text.
# ===========================================================================
for my $name (qw(dim_mismatch compression_type lvq_bad_pair))
{
    my ($case) = grep { $_->{name} eq $name } @cases;
    my $log_pos = length($node->log_content());

    my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
        \\set VERBOSITY verbose
        SET enable_seqscan = off;
        SELECT id FROM $case->{table} ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($ret, 0, "$case->{name}: scan fails (client never sees XX001 on this path)");

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/failed to load index \d+/,
        "$case->{name}: worker logs the load failure");
    like($log, $case->{pattern},
        "$case->{name}: worker log detail names the bad field/config");
}

is(wait_for_worker($node, 10), $worker_pid, 'worker survives every scan-path load failure');

# ===========================================================================
# Control index is untouched and must still work correctly throughout.
# ===========================================================================
{
    my $out = $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM mp_control_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100
        ) s;
    ));
    chomp $out;
    is($out, '50', 'untouched control index still returns correct results');
}

# ===========================================================================
# REINDEX recovers a corrupted index, as the hint promises.
# ===========================================================================
{
    my ($case) = grep { $_->{name} eq 'alpha' } @cases;
    $node->safe_psql('postgres', "REINDEX INDEX $case->{index};");
    my $out = $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM $case->{table} ORDER BY val <-> '[$query_sql]' LIMIT 100
        ) s;
    ));
    chomp $out;
    is($out, '50', 'REINDEX recovers a corrupted index and a scan then works');
}

# ===========================================================================
# DROP INDEX on a corrupted index must succeed; the object-access hook path
# must not itself read the metapage and fail.
# ===========================================================================
{
    my ($case) = grep { $_->{name} eq 'build_window_size' } @cases;
    my ($ret) = $node->psql('postgres', "DROP INDEX $case->{index};");
    is($ret, 0, 'DROP INDEX on a corrupted index succeeds');
}

is(wait_for_worker($node, 10), $worker_pid, 'worker pid unchanged after the full case set');

my $full_log = $node->log_content();
unlike($full_log, qr/terminated by signal/, 'no worker process was signal-terminated');
unlike($full_log, qr/server process .* exited with exit code/,
    'no backend crashed during the case set');

$node->stop;

done_testing();
