#!/bin/bash
set -euo pipefail

# inspect.sh — Developer inspection tool for the PostgreSQL 3-way hybrid sharded cluster.
# Displays cluster topology, hybrid partition layout, row distribution, and routing examples.

PGUSER="${POSTGRES_USER:-postgres}"
APP_DB="${APP_DB:-appdb}"

run_sql() {
    local container="$1"
    local db="$2"
    local sql="$3"
    docker exec "$container" psql -U "$PGUSER" -d "$db" -c "$sql"
}

echo "================================================================="
echo "            PostgreSQL 3-Way Hybrid Cluster Status               "
echo "================================================================="

echo ""
echo "[1] Cluster Topology"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "[2] Coordinator (pg1) - Partition Architecture"
run_sql pg1 "$APP_DB" "
SELECT
    c.relname AS partition_name,
    CASE c.relkind
        WHEN 'r' THEN 'LOCAL TABLE (on pg1 disk)'
        WHEN 'f' THEN 'FOREIGN TABLE (on remote shard)'
    END AS storage_type,
    COALESCE(fs.foreign_server_name, 'local (pg1)') AS target_server,
    pg_get_expr(c.relpartbound, c.oid) AS partition_bound
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
LEFT JOIN information_schema.foreign_tables fs ON fs.foreign_table_name = c.relname
WHERE i.inhparent = 'users'::regclass
ORDER BY c.relname;
"

echo ""
echo "[3] Shard Distribution & Storage Stats"
run_sql pg1 "$APP_DB" "
SELECT
    'users (aggregated view)' AS table_scope,
    count(*) AS total_rows,
    pg_size_pretty(pg_total_relation_size('users')) AS total_local_size
FROM users;
"

echo "  Physical Breakdown across all 3 nodes:"
p0_count=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_p0;" 2>/dev/null || echo "0")
p0_size=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT pg_size_pretty(pg_total_relation_size('users_p0'));" 2>/dev/null || echo "0 kB")

s1_count=$(docker exec pg2 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_1;" 2>/dev/null || echo "0")
s1_size=$(docker exec pg2 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT pg_size_pretty(pg_total_relation_size('users_shard_1'));" 2>/dev/null || echo "0 kB")

s2_count=$(docker exec pg3 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_2;" 2>/dev/null || echo "0")
s2_size=$(docker exec pg3 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT pg_size_pretty(pg_total_relation_size('users_shard_2'));" 2>/dev/null || echo "0 kB")

printf "    %-26s | Rows: %-6s | Size: %-10s\n" "pg1 Local (users_p0)" "$p0_count" "$p0_size"
printf "    %-26s | Rows: %-6s | Size: %-10s\n" "pg2 Shard 1 (users_shard_1)" "$s1_count" "$s1_size"
printf "    %-26s | Rows: %-6s | Size: %-10s\n" "pg3 Shard 2 (users_shard_2)" "$s2_count" "$s2_size"

echo ""
echo "[4] Sample Data Preview"
echo "  Local Shard 0 on pg1 (users_p0):"
run_sql pg1 "$APP_DB" "SELECT id, username, email FROM users_p0 ORDER BY id LIMIT 3;"

echo "  Remote Shard 1 on pg2 (users_shard_1):"
run_sql pg2 "$APP_DB" "SELECT id, username, email FROM users_shard_1 ORDER BY id LIMIT 3;"

echo "  Remote Shard 2 on pg3 (users_shard_2):"
run_sql pg3 "$APP_DB" "SELECT id, username, email FROM users_shard_2 ORDER BY id LIMIT 3;"

echo ""
echo "[5] Query Planner Routing Examples (Partition Pruning)"
echo "  Local Route (id = 2 -> evaluates to users_p0 on pg1):"
run_sql pg1 "$APP_DB" "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 2;"

echo "  Remote Route (id = 3 -> evaluates to users_p1 on pg2):"
run_sql pg1 "$APP_DB" "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 3;"

echo "================================================================="
