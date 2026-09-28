#!/bin/bash
set -euo pipefail

# Runs on pg1 (primary) first boot via docker-entrypoint-initdb.d
# Creates the replication user, replication slots, and the app database.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-SQL
    -- Replication user
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPLICATOR_PASSWORD}';

    -- Pre-create physical replication slots so standbys can connect immediately
    SELECT pg_create_physical_replication_slot('replica_pg2');
    SELECT pg_create_physical_replication_slot('replica_pg3');
SQL

echo "[init-pg1] primary initialised: replicator role and slots replica_pg2/pg3"
