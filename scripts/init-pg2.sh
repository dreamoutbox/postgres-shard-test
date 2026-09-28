#!/bin/bash
set -euo pipefail

# Runs on pg2 (data shard 1) first boot
echo "[init-pg2] creating physical shard table users_shard_1 in ${APP_DB}..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB" <<-SQL
    CREATE TABLE IF NOT EXISTS users_shard_1 (
        id BIGINT NOT NULL,
        username TEXT NOT NULL,
        email TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now(),
        CONSTRAINT users_shard_1_pkey PRIMARY KEY (id)
    );
SQL

echo "[init-pg2] shard1 table users_shard_1 ready."
