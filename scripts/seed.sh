#!/bin/bash
set -euo pipefail

# seed.sh — Inserts sample rows into the coordinator (pg1).
# Usage:
#   ./scripts/seed.sh [count]     (default: 10)

PGUSER="${POSTGRES_USER:-postgres}"
APP_DB="${APP_DB:-appdb}"
COUNT="${1:-10}"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -le 0 ]; then
    echo "Error: count must be a positive integer."
    exit 1
fi

echo "Inserting $COUNT sample row(s) through coordinator (pg1)..."

docker exec pg1 psql -U "$PGUSER" -d "$APP_DB" -c "
DO \$\$
DECLARE
    v_start_id BIGINT;
    v_count INT := $COUNT;
BEGIN
    SELECT COALESCE(MAX(id), 0) + 1 INTO v_start_id FROM users;

    INSERT INTO users (id, username, email)
    SELECT
        i,
        'user_' || i,
        'user_' || i || '@example.com'
    FROM generate_series(v_start_id, v_start_id + v_count - 1) AS i;
END \$\$;
"

echo "Inserted $COUNT row(s) successfully."
echo ""

# Quick shard distribution summary
s1_count=$(docker exec pg2 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_1;" 2>/dev/null || echo "0")
s2_count=$(docker exec pg3 psql -U "$PGUSER" -d "$APP_DB" -tAq -c "SELECT count(*) FROM users_shard_2;" 2>/dev/null || echo "0")
total=$((s1_count + s2_count))

echo "Current Distribution:"
echo "  Shard 1 (pg2): $s1_count rows"
echo "  Shard 2 (pg3): $s2_count rows"
echo "  Total:         $total rows across cluster"
