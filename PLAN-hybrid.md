# Implementation Plan: PostgreSQL Hybrid Sharding Architecture

A comprehensive plan to transform the cluster into a **3-Way Hybrid Sharding Architecture**, where `pg1` acts as both the Coordinator and Shard 0 (storing data locally), while `pg2` and `pg3` act as remote data shards.

---

## 1. Architecture Overview (Hybrid Model)

```
                    +-----------------------------+
                    |  Application / psql Client   |
                    +--------------+--------------+
                                   |
                                   v  (Port 5432)
                    +---------------------------------------------+
                    |           Coordinator Node (pg1)            |
                    |  - users (Partitioned Root, HASH id)        |
                    |  - users_p0 (LOCAL Table on pg1 disk)       |
                    |  - postgres_fdw foreign servers to pg2, pg3 |
                    +--------------+--------------+---------------+
                                   |              |
             (modulus 3 = 1)       |              |   (modulus 3 = 2)
            +----------------------+              +----------------------+
            |                                                            |
            v                                                            v
  +---------------------------+                        +---------------------------+
  |    Shard 1 (pg2, 5433)    |                        |    Shard 2 (pg3, 5434)    |
  |  - users_shard_1 (Table)  |                        |  - users_shard_2 (Table)  |
  +---------------------------+                        +---------------------------+
```

### Partition Distribution (Modulus 3)
- **Remainder 0**: Stored locally on `pg1` in physical partition `users_p0`.
- **Remainder 1**: Remoted via `postgres_fdw` to `pg2` in `users_shard_1`.
- **Remainder 2**: Remoted via `postgres_fdw` to `pg3` in `users_shard_2`.

---

## 2. Phased Implementation Plan

### Phase 1: Reconfigure Coordinator Schema for Hybrid Partitioning
- Goal: Update `pg1` initialization schema to partition with `MODULUS 3`, creating a local physical table for partition 0 and foreign partitions for shards 1 and 2.
- Tasks:
  - [x] Update `scripts/init-pg1.sh`:
    - Modify `users` table partitioning logic to use `MODULUS 3`.
    - Create `users_p0` as a local standard table: `CREATE TABLE users_p0 PARTITION OF users FOR VALUES WITH (MODULUS 3, REMAINDER 0)`.
    - Create `users_p1` as a foreign table on `shard1_server` for `REMAINDER 1`.
    - Create `users_p2` as a foreign table on `shard2_server` for `REMAINDER 2`.
  - [x] Test cluster boot (`./scripts/stop.sh && ./scripts/start.sh`).
  - [x] Inspect coordinator catalog: verify `users` has 1 local partition and 2 foreign partitions.
- Done when: `./scripts/stop.sh && ./scripts/start.sh` boots healthy; `\d+ users` on `pg1` shows `users_p0` (TABLE), `users_p1` (FOREIGN TABLE), and `users_p2` (FOREIGN TABLE).

### Phase 2: Update Automated Sharding Test Suite for 3-Way Hybrid Routing
- Goal: Adapt `scripts/test-sharding.sh` to verify 3-way data placement across local storage and remote shards.
- Tasks:
  - [x] Update catalog checks to assert 1 local partition and 2 foreign partitions.
  - [x] Update batch insert test to insert enough rows (e.g. 12 rows) to populate all 3 partitions.
  - [x] Add assertions checking:
    - `pg1` local table `users_p0` contains rows (> 0).
    - `pg2` remote table `users_shard_1` contains rows (> 0).
    - `pg3` remote table `users_shard_2` contains rows (> 0).
    - Sum of all 3 partitions equals total inserted rows.
  - [x] Update partition pruning tests to verify `EXPLAIN` isolates `users_p0` (local scan), `users_p1` (foreign scan), and `users_p2` (foreign scan).
  - [x] Update UPDATE and DELETE assertions to cover local partition modifications.
- Done when: `./scripts/test-sharding.sh` passes 100% of checks on a freshly booted hybrid cluster.

### Phase 3: Update Tooling and Documentation (seed.sh, inspect.sh, README.md)
- Goal: Align developer inspection scripts and documentation with the 3-way hybrid distribution.
- Tasks:
  - [x] Update `scripts/seed.sh` summary output to report row counts for:
    - `pg1 (local partition)`
    - `pg2 (shard 1)`
    - `pg3 (shard 2)`
  - [x] Update `scripts/inspect.sh` to display:
    - Local storage stats on `pg1` (`users_p0` size and rows).
    - Remote storage stats on `pg2` and `pg3`.
    - Sample data preview from `users_p0` on `pg1`.
  - [x] Update `README.md` architectural diagrams, partition definitions, and query walkthroughs to document the hybrid model.
- Done when: Running `./scripts/seed.sh 15 && ./scripts/inspect.sh` displays rows distributed across `pg1`, `pg2`, and `pg3` with accurate size breakdowns.

---

## 3. Unknowns, Risks & Assumptions

- **Assumptions**:
  - We retain the existing 3 containers (`pg1`, `pg2`, `pg3`).
  - No changes needed to `docker-compose.yml` or container networking.
- **Risks**:
  - `TRUNCATE users` on `pg1`: Postgres natively supports truncating mixed local and foreign partitions simultaneously, but transactions involving foreign tables require `max_prepared_transactions` to remain enabled on `pg1` (already configured).
