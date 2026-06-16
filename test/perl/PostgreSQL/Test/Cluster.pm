# Copyright (c) 2021-2026, PostgreSQL Global Development Group
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

package PostgreSQL::Test::Cluster;

use PostgresNode;

sub new
{
	my ($class, $name) = @_;
	return get_new_node($name);
}

1;
