#!/bin/bash
set -euo pipefail

# Runs on pg1 (coordinator) first boot
echo "[init-pg1] configuring postgres_fdw and declarative sharded partitions..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB" <<-SQL
    -- 1. Enable postgres_fdw extension
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;

    -- 2. Define foreign shard servers
    CREATE SERVER IF NOT EXISTS shard1_server
        FOREIGN DATA WRAPPER postgres_fdw
        OPTIONS (
            host 'pg2',
            port '5432',
            dbname '${APP_DB}',
            fetch_size '1000',
            batch_size '1000',
            updatable 'true'
        );

    CREATE SERVER IF NOT EXISTS shard2_server
        FOREIGN DATA WRAPPER postgres_fdw
        OPTIONS (
            host 'pg3',
            port '5432',
            dbname '${APP_DB}',
            fetch_size '1000',
            batch_size '1000',
            updatable 'true'
        );

    -- 3. User mappings for authentication
    CREATE USER MAPPING IF NOT EXISTS FOR ${POSTGRES_USER}
        SERVER shard1_server
        OPTIONS (user '${POSTGRES_USER}', password '${POSTGRES_PASSWORD}');

    CREATE USER MAPPING IF NOT EXISTS FOR ${POSTGRES_USER}
        SERVER shard2_server
        OPTIONS (user '${POSTGRES_USER}', password '${POSTGRES_PASSWORD}');

    -- 4. Root partitioned table on Coordinator (holds no local data)
    -- Note: Native Postgres foreign partitions cannot have UNIQUE/PRIMARY KEY
    -- constraints on the root table; primary keys are enforced directly on the shard tables.
    CREATE TABLE IF NOT EXISTS users (
        id BIGINT NOT NULL,
        username TEXT NOT NULL,
        email TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now()
    ) PARTITION BY HASH (id);

    -- 5. Partitions (Hybrid: 1 Local on pg1, 2 Foreign on pg2 & pg3)
    -- Partition 0: Stored LOCALLY on pg1 disk
    CREATE TABLE IF NOT EXISTS users_p0
        PARTITION OF users
        FOR VALUES WITH (MODULUS 3, REMAINDER 0);

    -- Local index on pg1's partition
    CREATE INDEX IF NOT EXISTS users_p0_id_idx ON users_p0 (id);

    -- Partition 1: Stored on remote Shard 1 (pg2)
    CREATE FOREIGN TABLE IF NOT EXISTS users_p1
        PARTITION OF users
        FOR VALUES WITH (MODULUS 3, REMAINDER 1)
        SERVER shard1_server
        OPTIONS (table_name 'users_shard_1');

    -- Partition 2: Stored on remote Shard 2 (pg3)
    CREATE FOREIGN TABLE IF NOT EXISTS users_p2
        PARTITION OF users
        FOR VALUES WITH (MODULUS 3, REMAINDER 2)
        SERVER shard2_server
        OPTIONS (table_name 'users_shard_2');
SQL

echo "[init-pg1] coordinator sharding setup complete."
