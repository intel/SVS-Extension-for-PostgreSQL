# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 66_svs_payload_dir_modes.pl — SVS payload subdirectory modes are set
# explicitly by VamanaEnsureSaveDir, not left to the inherited process
# umask. Under PostgreSQL's normal umask, an unfixed and a fixed build both
# land at 0700/0750, so this test widens the backend's own umask before
# CREATE INDEX to make the two cases distinguishable.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('vamana_payload_dir_modes');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION vector;');
$node->safe_psql('postgres', 'CREATE EXTENSION svs;');
$node->safe_psql('postgres', 'CREATE EXTENSION svs_umask_test;');
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

# Widen the umask to 0 and build the index in the same backend/transaction
# so the CREATE INDEX save runs under that umask. The build happens in the
# backend (vamanabuild -> SerializeIndexToPages -> VamanaSaveIndexToDisk),
# so no other process is affected.
$node->safe_psql('postgres', qq(
    SELECT svs_test_set_umask(0);
    CREATE TABLE pdm_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO pdm_tbl (val)
        SELECT ARRAY[$array_sql]::vector
        FROM generate_series(1, 50) i;
    CREATE INDEX pdm_idx ON pdm_tbl USING vamana (val vector_l2_ops);
));

my $index_oid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_class WHERE relname = 'pdm_idx';");
chomp $index_oid;

my $index_dir = vamana_save_dir($node, 'postgres', $index_oid);
ok(-d $index_dir, 'on-disk index directory exists after CREATE INDEX');

my $control_mode = (stat($index_dir))[2] & 07777;
ok($control_mode == 0700 || $control_mode == 0750,
    sprintf('control: index directory mode is %04o (set by MakePGDirectory, same umask)',
            $control_mode));

my @payload_subdirs = qw(config graph data);
my %found;
for my $entry (glob("$index_dir/*"))
{
    $found{(split m{/}, $entry)[-1]} = 1 if -d $entry;
}

is_deeply([sort keys %found], [sort @payload_subdirs],
    'index directory contains exactly the config/graph/data payload subdirectories');

for my $subdir (@payload_subdirs)
{
    my $path = "$index_dir/$subdir";
    my $mode = (stat($path))[2] & 07777;
    is($mode, $control_mode,
        sprintf('%s directory mode is %04o, matching the control (not widened by umask 0)',
                $subdir, $control_mode));
}

my @payload_files;
for my $subdir (@payload_subdirs)
{
    push @payload_files, glob("$index_dir/$subdir/*");
}
ok(scalar @payload_files > 0, 'payload files exist to check');

# Residual, documented gap: the files SVS writes inside config/, graph/,
# and data/ still land per the process umask, because svs_index_save takes
# no mode parameter. This is expected to fail today; it will start passing
# once that gap closes upstream, which is this TODO block's intended signal.
TODO: {
    local $TODO = 'file modes depend on the inherited umask; no mode parameter in svs_index_save';
    my $all_restrictive = 1;
    for my $file (@payload_files)
    {
        my $mode = (stat($file))[2] & 07777;
        $all_restrictive = 0 if $mode & 0077;
    }
    ok($all_restrictive, 'payload files are not wider than pg_file_create_mode under umask 0');
}

done_testing();
