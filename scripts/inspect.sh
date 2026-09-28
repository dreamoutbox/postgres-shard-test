#!/bin/bash
set -euo pipefail

# inspect.sh — Developer inspection tool for the PostgreSQL sharded cluster.
# Displays cluster topology, shard row distribution, storage sizes, and query routing.

PGUSER="${POSTGRES_USER:-postgres}"
APP_DB="${APP_DB:-appdb}"

run_sql() {
    local container="$1"
    local db="$2"
    local sql="$3"
    docker exec "$container" psql -U "$PGUSER" -d "$db" -c "$sql"
}

echo "================================================================="
echo "                PostgreSQL Sharded Cluster Status                "
echo "================================================================="

echo ""
echo "[1] Cluster Topology"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "[2] Coordinator (pg1) - Foreign Shard Servers & Partitions"
run_sql pg1 "$APP_DB" "
SELECT
    f.foreign_table_name AS partition_table,
    f.foreign_server_name AS foreign_server,
    s.srvoptions[1] || ':' || s.srvoptions[2] AS remote_endpoint
FROM information_schema.foreign_tables f
JOIN pg_foreign_server s ON s.srvname = f.foreign_server_name
ORDER BY f.foreign_table_name;
"

echo ""
echo "[3] Shard Distribution & Storage Stats"
run_sql pg1 "$APP_DB" "
SELECT
    'users (coordinator)' AS location,
    count(*) AS total_rows,
    pg_size_pretty(pg_total_relation_size('users')) AS total_size
FROM users;
"

echo "  Shard Breakdown (Queried directly on shard nodes):"
s1_count=$(docker exec pg2 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_1;" 2>/dev/null || echo "0")
s1_size=$(docker exec pg2 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT pg_size_pretty(pg_total_relation_size('users_shard_1'));" 2>/dev/null || echo "0 kB")

s2_count=$(docker exec pg3 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_2;" 2>/dev/null || echo "0")
s2_size=$(docker exec pg3 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT pg_size_pretty(pg_total_relation_size('users_shard_2'));" 2>/dev/null || echo "0 kB")

printf "    %-20s | Rows: %-6s | Size: %-10s\n" "pg2 (users_shard_1)" "$s1_count" "$s1_size"
printf "    %-20s | Rows: %-6s | Size: %-10s\n" "pg3 (users_shard_2)" "$s2_count" "$s2_size"

echo ""
echo "[4] Sample Data Preview"
echo "  First 3 rows on Shard 1 (pg2):"
run_sql pg2 "$APP_DB" "SELECT id, username, email FROM users_shard_1 ORDER BY id LIMIT 3;"

echo "  First 3 rows on Shard 2 (pg3):"
run_sql pg3 "$APP_DB" "SELECT id, username, email FROM users_shard_2 ORDER BY id LIMIT 3;"

echo ""
echo "[5] Query Planner Routing Example (Partition Pruning)"
echo "  EXPLAIN query for single-key lookup (id = 1):"
run_sql pg1 "$APP_DB" "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 1;"

echo "================================================================="
