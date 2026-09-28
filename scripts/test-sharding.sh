#!/bin/bash
set -euo pipefail

# test-sharding.sh — comprehensive verification suite for 3-way hybrid sharding.
# Verifies:
#   1. Node connectivity (pg1 coordinator+shard0, pg2 shard1, pg3 shard2).
#   2. Hybrid catalog checks (1 local partition users_p0, 2 foreign partitions users_p1, users_p2).
#   3. Distributed batch inserts across local and remote partitions.
#   4. Physical partition distribution across pg1 (users_p0), pg2 (users_shard_1), and pg3 (users_shard_2).
#   5. Unified aggregation queries across all 3 nodes.
#   6. Query planner partition pruning (verifies single-partition routing for local and remote shards).
#   7. Distributed UPDATE propagation (both local and remote).
#   8. Distributed DELETE propagation (both local and remote).

PGUSER="${POSTGRES_USER:-postgres}"
APP_DB="${APP_DB:-appdb}"

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"
    local expected="$3"
    if [ "$result" = "$expected" ]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label — got: '$result', expected: '$expected'"
        FAIL=$((FAIL + 1))
    fi
}

run_sql() {
    local container="$1"
    local db="$2"
    local sql="$3"
    docker exec "$container" psql -U "$PGUSER" -d "$db" -tAq -c "$sql" 2>/dev/null
}

echo "=== PostgreSQL Hybrid Sharding Verification Suite ==="
echo ""

# 1. Connectivity & Readiness
echo "--- 1. Node Connectivity (waiting up to 30s) ---"
for node in pg1 pg2 pg3; do
    result=""
    for attempt in $(seq 1 30); do
        result=$(run_sql "$node" postgres "SELECT 1" || true)
        if [ "$result" = "1" ]; then
            break
        fi
        sleep 1
    done
    check "$node is online and responsive" "$result" "1"
done

# 2. Schema Catalog Checks on Coordinator
echo ""
echo "--- 2. Hybrid Partition Catalog Checks ---"
fdw_servers=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM pg_foreign_server WHERE srvname IN ('shard1_server', 'shard2_server');")
check "pg1 has 2 foreign shard servers defined" "$fdw_servers" "2"

local_partitions=$(run_sql pg1 "$APP_DB" "
SELECT count(*)
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'users'::regclass AND c.relkind = 'r';
")
check "pg1 has 1 local physical partition (users_p0)" "$local_partitions" "1"

foreign_partitions=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM information_schema.foreign_tables WHERE foreign_table_name IN ('users_p1', 'users_p2');")
check "pg1 has 2 foreign partitions bound to remote shards" "$foreign_partitions" "2"

# 3. Clean Slate & Batch Insert through Coordinator
echo ""
echo "--- 3. Distributed Batch Insert (12 rows) ---"
run_sql pg1 "$APP_DB" "TRUNCATE users;" > /dev/null

run_sql pg1 "$APP_DB" "
INSERT INTO users (id, username, email)
SELECT
    i,
    'user_' || i,
    'user_' || i || '@shard.test'
FROM generate_series(1, 12) AS i;
" > /dev/null

# 4. Verify Physical Placement across all 3 nodes
echo ""
echo "--- 4. Physical Data Placement across All 3 Nodes ---"
p0_rows=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users_p0;")
s1_rows=$(run_sql pg2 "$APP_DB" "SELECT count(*) FROM users_shard_1;")
s2_rows=$(run_sql pg3 "$APP_DB" "SELECT count(*) FROM users_shard_2;")
total_rows=$((p0_rows + s1_rows + s2_rows))

echo "  Local Shard 0 (pg1 users_p0):    $p0_rows rows"
echo "  Remote Shard 1 (pg2 users_shard_1): $s1_rows rows"
echo "  Remote Shard 2 (pg3 users_shard_2): $s2_rows rows"

if [ "$p0_rows" -gt 0 ] && [ "$s1_rows" -gt 0 ] && [ "$s2_rows" -gt 0 ]; then
    check "data is distributed across all 3 nodes (all > 0)" "true" "true"
else
    check "data is distributed across all 3 nodes (all > 0)" "false" "true"
fi
check "sum of rows across all partitions equals 12" "$total_rows" "12"

# 5. Unified Reads from Coordinator
echo ""
echo "--- 5. Coordinator Unified Read & Aggregation ---"
coord_count=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users;")
check "coordinator returns aggregate count of all nodes (12)" "$coord_count" "12"

# 6. Partition Pruning Verification (Local vs Remote)
echo ""
echo "--- 6. Query Planner Partition Pruning ---"

# id = 2 routes to users_p0 (Local Shard 0)
plan_id2=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 2;")
if echo "$plan_id2" | grep -q "users_p0" && ! echo "$plan_id2" | grep -q "users_p1" && ! echo "$plan_id2" | grep -q "users_p2"; then
    check "id = 2 prunes remote shards and scans only local users_p0" "pruned" "pruned"
else
    check "id = 2 prunes remote shards and scans only local users_p0" "$plan_id2" "pruned"
fi

# id = 3 routes to users_p1 (Remote Shard 1 on pg2)
plan_id3=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 3;")
if echo "$plan_id3" | grep -q "users_p1" && ! echo "$plan_id3" | grep -q "users_p0" && ! echo "$plan_id3" | grep -q "users_p2"; then
    check "id = 3 prunes local & shard2 and scans only foreign users_p1" "pruned" "pruned"
else
    check "id = 3 prunes local & shard2 and scans only foreign users_p1" "$plan_id3" "pruned"
fi

# id = 1 routes to users_p2 (Remote Shard 2 on pg3)
plan_id1=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 1;")
if echo "$plan_id1" | grep -q "users_p2" && ! echo "$plan_id1" | grep -q "users_p0" && ! echo "$plan_id1" | grep -q "users_p1"; then
    check "id = 1 prunes local & shard1 and scans only foreign users_p2" "pruned" "pruned"
else
    check "id = 1 prunes local & shard1 and scans only foreign users_p2" "$plan_id1" "pruned"
fi

# 7. Distributed UPDATE
echo ""
echo "--- 7. Distributed UPDATE Propagation ---"
# Update local partition row (id = 2)
run_sql pg1 "$APP_DB" "UPDATE users SET username = 'local_user_2' WHERE id = 2;" > /dev/null
updated_local=$(run_sql pg1 "$APP_DB" "SELECT username FROM users_p0 WHERE id = 2;")
check "UPDATE reflects on local partition users_p0" "$updated_local" "local_user_2"

# Update remote partition row (id = 3)
run_sql pg1 "$APP_DB" "UPDATE users SET username = 'remote_user_3' WHERE id = 3;" > /dev/null
updated_remote=$(run_sql pg2 "$APP_DB" "SELECT username FROM users_shard_1 WHERE id = 3;")
check "UPDATE reflects on remote shard 1 (users_shard_1)" "$updated_remote" "remote_user_3"

# 8. Distributed DELETE
echo ""
echo "--- 8. Distributed DELETE Propagation ---"
# Delete local row (id = 2)
run_sql pg1 "$APP_DB" "DELETE FROM users WHERE id = 2;" > /dev/null
deleted_local=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users_p0 WHERE id = 2;")
check "DELETE removes row from local partition users_p0" "$deleted_local" "0"

# Delete remote row (id = 3)
run_sql pg1 "$APP_DB" "DELETE FROM users WHERE id = 3;" > /dev/null
deleted_remote=$(run_sql pg2 "$APP_DB" "SELECT count(*) FROM users_shard_1 WHERE id = 3;")
check "DELETE removes row from remote shard 1 (users_shard_1)" "$deleted_remote" "0"

remaining_coord=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users;")
check "coordinator total count after deletes is 10" "$remaining_coord" "10"

# Clean up
run_sql pg1 "$APP_DB" "TRUNCATE users;" > /dev/null

echo ""
echo "=== Test Summary: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
