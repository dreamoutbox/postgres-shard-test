#!/bin/bash
set -euo pipefail

# Standby entrypoint for pg2.
# If PGDATA is uninitialised, clone primary via pg_basebackup, then drop
# standby.signal and the overlay postgresql.conf before handing off to the
# normal postgres daemon.

PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    echo "[pg2-entrypoint] PGDATA empty — running pg_basebackup from pg1..."

    mkdir -p "$PGDATA"
    chown -R postgres:postgres /var/lib/postgresql
    chmod 700 "$PGDATA"

    PGPASSWORD="$REPLICATOR_PASSWORD" gosu postgres pg_basebackup \
        --host=pg1 \
        --port=5432 \
        --username=replicator \
        --pgdata="$PGDATA" \
        --wal-method=stream \
        --slot=replica_pg2 \
        --checkpoint=fast \
        --verbose

    # Mark as standby
    touch "$PGDATA/standby.signal"

    # Copy our overlay conf (primary_conninfo etc.) into PGDATA so postgres picks it up
    cp /etc/postgresql/postgresql.conf "$PGDATA/postgresql.conf"
    cp /etc/postgresql/pg_hba.conf "$PGDATA/pg_hba.conf"

    # Substitute REPLICATOR_PASSWORD placeholder in the copied conf
    sed -i "s/\${REPLICATOR_PASSWORD}/$REPLICATOR_PASSWORD/g" "$PGDATA/postgresql.conf"

    # Fix ownership of all copied files
    chown -R postgres:postgres /var/lib/postgresql
    chmod 700 "$PGDATA"

    echo "[pg2-entrypoint] basebackup complete, standby.signal written"
else
    echo "[pg2-entrypoint] PGDATA already initialised, skipping basebackup"
fi

exec gosu postgres postgres -D "$PGDATA"
