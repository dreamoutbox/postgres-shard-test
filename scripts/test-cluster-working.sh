#!/bin/bash
set -euo pipefail

# test-cluster-working.sh — asserts the 3-node streaming replication cluster is working.
# Tests:
#   1. Container health and postgres response on all 3 nodes (pg1, pg2, pg3).
#   2. pg1 is leader/primary (pg_is_in_recovery = false).
#   3. pg2 and pg3 are followers/standbys (pg_is_in_recovery = true).
#   4. pg1 has 2 active streaming replication connections.
#   5. Data written on pg1 (leader) is replicated to pg2 and pg3 (followers).

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

echo "=== Postgres 3-Node Cluster Verification ==="
echo ""

# 1. Connectivity & Postgres Readiness
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
    check "$node is responsive" "$result" "1"
done

# 2. Roles: 1 Leader (pg1), 2 Followers (pg2, pg3)
echo ""
echo "--- 2. Cluster Roles ---"
pg1_recovery=$(run_sql pg1 postgres "SELECT pg_is_in_recovery()")
check "pg1 is leader (pg_is_in_recovery = f)" "$pg1_recovery" "f"

pg2_recovery=$(run_sql pg2 postgres "SELECT pg_is_in_recovery()")
check "pg2 is follower (pg_is_in_recovery = t)" "$pg2_recovery" "t"

pg3_recovery=$(run_sql pg3 postgres "SELECT pg_is_in_recovery()")
check "pg3 is follower (pg_is_in_recovery = t)" "$pg3_recovery" "t"

# 3. Streaming Replication Status on Leader
echo ""
echo "--- 3. Replication Status on Leader (pg1) ---"
replica_count="0"
for attempt in $(seq 1 15); do
    replica_count=$(run_sql pg1 postgres "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'" || echo "0")
    if [ "$replica_count" = "2" ]; then
        break
    fi
    sleep 1
done
check "pg1 has 2 active streaming followers" "$replica_count" "2"

echo "  Replication details:"
docker exec pg1 psql -U "$PGUSER" -d postgres -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;"

# 4. Data Replication (Write on pg1 -> Read from pg2 & pg3)
echo ""
echo "--- 4. Write Replication Test ---"
TEST_TABLE="cluster_test_$(date +%s)"
TEST_VALUE="shard_prep_$(date +%s)"

run_sql pg1 "$APP_DB" "CREATE TABLE $TEST_TABLE (id serial primary key, val text);" > /dev/null
run_sql pg1 "$APP_DB" "INSERT INTO $TEST_TABLE (val) VALUES ('$TEST_VALUE');" > /dev/null

# Wait up to 5 seconds for replication to catch up
pg2_val=""
pg3_val=""
for attempt in $(seq 1 10); do
    pg2_val=$(run_sql pg2 "$APP_DB" "SELECT val FROM $TEST_TABLE LIMIT 1" 2>/dev/null || echo "")
    pg3_val=$(run_sql pg3 "$APP_DB" "SELECT val FROM $TEST_TABLE LIMIT 1" 2>/dev/null || echo "")
    if [ "$pg2_val" = "$TEST_VALUE" ] && [ "$pg3_val" = "$TEST_VALUE" ]; then
        break
    fi
    sleep 0.5
done

check "pg2 (follower) received write from pg1" "$pg2_val" "$TEST_VALUE"
check "pg3 (follower) received write from pg1" "$pg3_val" "$TEST_VALUE"

# Cleanup
run_sql pg1 "$APP_DB" "DROP TABLE $TEST_TABLE;" > /dev/null

echo ""
echo "=== Test Summary: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
