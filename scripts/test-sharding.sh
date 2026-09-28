#!/bin/bash
set -euo pipefail

# test-sharding.sh — comprehensive verification suite for postgres_fdw declarative sharding.
# Verifies:
#   1. Node connectivity (pg1 coordinator, pg2 shard1, pg3 shard2).
#   2. Foreign server and user mapping catalog entries on coordinator.
#   3. Distributed batch inserts routed transparently through coordinator.
#   4. Physical partition distribution across pg2 (users_shard_1) and pg3 (users_shard_2).
#   5. Unified aggregation queries across shards.
#   6. Query planner partition pruning (verifies single-shard routing on key lookup).
#   7. Distributed UPDATE propagation.
#   8. Distributed DELETE propagation.

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

echo "=== PostgreSQL Sharding Verification Suite ==="
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
echo "--- 2. Foreign Partition Catalog Checks ---"
fdw_servers=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM pg_foreign_server WHERE srvname IN ('shard1_server', 'shard2_server');")
check "pg1 has 2 foreign shard servers defined" "$fdw_servers" "2"

foreign_tables=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM information_schema.foreign_tables WHERE foreign_table_name IN ('users_p0', 'users_p1');")
check "pg1 has 2 foreign partitions bound to shards" "$foreign_tables" "2"

# 3. Clean Slate & Batch Insert through Coordinator
echo ""
echo "--- 3. Distributed Batch Insert ---"
run_sql pg1 "$APP_DB" "TRUNCATE users;" > /dev/null

run_sql pg1 "$APP_DB" "
INSERT INTO users (id, username, email) VALUES
    (1, 'alice', 'alice@shard.test'),
    (2, 'bob', 'bob@shard.test'),
    (3, 'carol', 'carol@shard.test'),
    (4, 'david', 'david@shard.test'),
    (5, 'eve', 'eve@shard.test'),
    (6, 'frank', 'frank@shard.test');
" > /dev/null

# 4. Verify Physical Placement on Shard Nodes
echo ""
echo "--- 4. Physical Data Placement on Shard Nodes ---"
shard1_rows=$(run_sql pg2 "$APP_DB" "SELECT count(*) FROM users_shard_1;")
shard2_rows=$(run_sql pg3 "$APP_DB" "SELECT count(*) FROM users_shard_2;")
total_shard_rows=$((shard1_rows + shard2_rows))

echo "  Shard 1 (pg2) row count: $shard1_rows"
echo "  Shard 2 (pg3) row count: $shard2_rows"

if [ "$shard1_rows" -gt 0 ] && [ "$shard2_rows" -gt 0 ]; then
    check "data is distributed across both shards (both > 0)" "true" "true"
else
    check "data is distributed across both shards (both > 0)" "false" "true"
fi
check "sum of rows on shards matches inserted total (6)" "$total_shard_rows" "6"

# 5. Unified Reads from Coordinator
echo ""
echo "--- 5. Coordinator Unified Read & Aggregation ---"
coord_count=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users;")
check "coordinator returns aggregate count of all shards (6)" "$coord_count" "6"

# 6. Partition Pruning Verification
echo ""
echo "--- 6. Query Planner Partition Pruning ---"
# id = 1 hashes to users_p0 (Shard 1); plan must prune users_p1
plan_id1=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 1;")
if echo "$plan_id1" | grep -q "users_p0" && ! echo "$plan_id1" | grep -q "users_p1"; then
    check "id = 1 query prunes users_p1 and scans only users_p0" "pruned" "pruned"
else
    check "id = 1 query prunes users_p1 and scans only users_p0" "$plan_id1" "pruned"
fi

# id = 3 hashes to users_p1 (Shard 2); plan must prune users_p0
plan_id3=$(docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 3;")
if echo "$plan_id3" | grep -q "users_p1" && ! echo "$plan_id3" | grep -q "users_p0"; then
    check "id = 3 query prunes users_p0 and scans only users_p1" "pruned" "pruned"
else
    check "id = 3 query prunes users_p0 and scans only users_p1" "$plan_id3" "pruned"
fi

# 7. Distributed UPDATE
echo ""
echo "--- 7. Distributed UPDATE Propagation ---"
run_sql pg1 "$APP_DB" "UPDATE users SET username = 'alice_updated' WHERE id = 1;" > /dev/null
updated_on_shard1=$(run_sql pg2 "$APP_DB" "SELECT username FROM users_shard_1 WHERE id = 1;")
check "UPDATE on coordinator reflects directly on physical shard 1" "$updated_on_shard1" "alice_updated"

# 8. Distributed DELETE
echo ""
echo "--- 8. Distributed DELETE Propagation ---"
run_sql pg1 "$APP_DB" "DELETE FROM users WHERE id = 1;" > /dev/null
deleted_on_shard1=$(run_sql pg2 "$APP_DB" "SELECT count(*) FROM users_shard_1 WHERE id = 1;")
check "DELETE on coordinator removes row from physical shard 1" "$deleted_on_shard1" "0"

remaining_coord=$(run_sql pg1 "$APP_DB" "SELECT count(*) FROM users;")
check "coordinator total count after delete is 5" "$remaining_coord" "5"

# Clean up
run_sql pg1 "$APP_DB" "TRUNCATE users;" > /dev/null

echo ""
echo "=== Test Summary: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
