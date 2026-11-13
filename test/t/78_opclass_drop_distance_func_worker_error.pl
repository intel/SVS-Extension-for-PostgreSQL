# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 78_opclass_drop_distance_func_worker_error.pl -- VamanaGetDistanceMetric's
# "no distance function found for vamana index" error is reachable from the
# background worker, not just dead code behind core's own earlier check on
# the backend path.  Dropping support function 1 from an opclass's family
# after a successful build leaves the worker with no way to classify the
# index's distance metric the next time it tries to load it.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('opclass_drop_distance_func');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

ok(wait_for_worker($node) =~ /^\d+$/, 'worker is running');

# FUNCTION 1 is added as a loose family member (not declared directly on
# the opclass), since an opclass's own required support function cannot
# be dropped while that opclass still needs it; a loose member can.
$node->safe_psql('postgres', qq(
	CREATE OPERATOR CLASS drop_distance_func_ops
		FOR TYPE vector USING vamana AS
		OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops;

	ALTER OPERATOR FAMILY drop_distance_func_ops USING vamana
		ADD FUNCTION 1 (vector, vector) vector_l2_squared_distance(vector, vector);

	CREATE TABLE drop_distance_func_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO drop_distance_func_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
	CREATE INDEX drop_distance_func_idx ON drop_distance_func_tbl
		USING vamana (val drop_distance_func_ops);
));

$node->safe_psql('postgres',
	"ALTER OPERATOR FAMILY drop_distance_func_ops USING vamana "
  . "DROP FUNCTION 1 (vector, vector);");

# Force a fresh load attempt: svs_restart_worker drops the worker's resident
# cache, so the index is not-yet-loaded again regardless of whether the
# build itself left it resident.
my $log_offset = -s $node->logfile;
$node->safe_psql('postgres', "SELECT svs_restart_worker('postgres');");
ok(wait_for_worker($node) =~ /^\d+$/, 'worker respawned after restart');

# svs_warmup_index's own SQL-level success/failure is not asserted on here:
# it currently reports success even when the worker's load failed (a
# separate, out-of-scope bug). The worker's log is the one place this
# failure is actually observable.
$node->safe_psql('postgres', "SELECT svs_warmup_index('drop_distance_func_idx');");

$node->wait_for_log(qr/no distance function found for vamana index/, $log_offset);
pass('worker logs the extension\'s own error after support function 1 is dropped');

$node->stop;

done_testing();
