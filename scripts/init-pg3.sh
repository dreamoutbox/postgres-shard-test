#!/bin/bash
set -euo pipefail

# Runs on pg3 (data shard 2) first boot
echo "[init-pg3] creating physical shard table users_shard_2 in ${APP_DB}..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB" <<-SQL
    CREATE TABLE IF NOT EXISTS users_shard_2 (
        id BIGINT NOT NULL,
        username TEXT NOT NULL,
        email TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now(),
        CONSTRAINT users_shard_2_pkey PRIMARY KEY (id)
    );
SQL

echo "[init-pg3] shard2 table users_shard_2 ready."
