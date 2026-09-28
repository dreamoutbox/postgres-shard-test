# PostgreSQL Sharding Architecture & Implementation Plan

A comprehensive guide and execution plan for setting up native horizontal sharding in PostgreSQL using **Declarative Table Partitioning** and **Foreign Data Wrappers (`postgres_fdw`)**.

---

## 1. Architectural Concept & Tutorial

### Sharding vs. Replication: What Changed?
In our previous setup, we built **Streaming Replication**:
- **1 Leader (`pg1`) + 2 Followers (`pg2`, `pg3`)**: Every node held a full byte-for-byte copy of the same data. Only `pg1` accepted writes. Read scalability increased, but write throughput and storage were capped by a single machine.

In **Sharding (Horizontal Partitioning across Nodes)**:
- Data is distributed horizontally: Shard 1 holds row subset A, Shard 2 holds row subset B.
- Storage capacity and write throughput scale horizontally across machines.
- **Node Roles**:
  - **Coordinator Node (`pg-coordinator` / `pg1`)**: Receives application traffic. Stores the master partitioned table schema, foreign server definitions, and routing rules. Holds no actual table data itself.
  - **Data Shard 1 (`pg-shard1` / `pg2`)**: Standalone writable PostgreSQL database storing partition 1 (`users_shard_1`).
  - **Data Shard 2 (`pg-shard2` / `pg3`)**: Standalone writable PostgreSQL database storing partition 2 (`users_shard_2`).

```
                    +-----------------------------+
                    |  Application / psql Client   |
                    +--------------+--------------+
                                   |
                                   v  (Port 5432)
                    +-----------------------------+
                    |    Coordinator (pg1)        |
                    |  - users (Partitioned Root) |
                    |  - postgres_fdw extension   |
                    +--------------+--------------+
                                   |
                +------------------+------------------+
                |                                     |
   (FDW Remoting: modulus 2 = 0)         (FDW Remoting: modulus 2 = 1)
                |                                     |
                v                                     v
  +---------------------------+         +---------------------------+
  |    Shard 1 (pg2, 5433)    |         |    Shard 2 (pg3, 5434)    |
  |  - users_shard_1 (Table)  |         |  - users_shard_2 (Table)  |
  +---------------------------+         +---------------------------+
```

---

### How PostgreSQL Native Sharding Works (Step-by-Step)

#### Step 1: The Remote Data Shards (`pg2` and `pg3`)
Each data shard is an independent PostgreSQL instance. It hosts the physical concrete table for its partition slice.
```sql
-- On Shard 1 (pg2):
CREATE TABLE users_shard_1 (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- On Shard 2 (pg3):
CREATE TABLE users_shard_2 (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

#### Step 2: The Foreign Data Wrapper on Coordinator (`pg1`)
PostgreSQL includes the `postgres_fdw` extension (standard in all Postgres distributions). This lets Postgres query external Postgres servers like local tables.
```sql
-- On Coordinator:
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Define remote shard connections
CREATE SERVER shard1_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg2', port '5432', dbname 'appdb');

CREATE SERVER shard2_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg3', port '5432', dbname 'appdb');

-- Map local coordinator user to remote shard credentials
CREATE USER MAPPING FOR postgres
    SERVER shard1_server
    OPTIONS (user 'postgres', password 'postgres');

CREATE USER MAPPING FOR postgres
    SERVER shard2_server
    OPTIONS (user 'postgres', password 'postgres');
```

#### Step 3: Declarative Partitioning Attached to Foreign Tables
On the coordinator, we create the root table using `PARTITION BY HASH (id)` (or `RANGE`):
```sql
-- Root partitioned table (holds 0 rows locally):
CREATE TABLE users (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
) PARTITION BY HASH (id);

-- Attach Shard 1 as Foreign Table partition:
CREATE FOREIGN TABLE users_p0
    PARTITION OF users
    FOR VALUES WITH (MODULUS 2, REMAINDER 0)
    SERVER shard1_server
    OPTIONS (table_name 'users_shard_1');

-- Attach Shard 2 as Foreign Table partition:
CREATE FOREIGN TABLE users_p1
    PARTITION OF users
    FOR VALUES WITH (MODULUS 2, REMAINDER 1)
    SERVER shard2_server
    OPTIONS (table_name 'users_shard_2');
```

#### Step 4: Transparent Routing & Execution
- **Inserts**: `INSERT INTO users (id, username, email) VALUES (1, 'alice', 'alice@example.com')`
  - Coordinator hashes `id = 1`.
  - Determines remainder (`1 % 2 = 1`).
  - Transparently forwards the row over network to `users_shard_2` on `pg3`.
- **Partition Pruning**: `SELECT * FROM users WHERE id = 1`
  - Coordinator inspects `WHERE id = 1`.
  - Prunes `users_p0` without connecting to `pg2`.
  - Only executes query on `pg3`.
- **Parallel Aggregate Pushdown**: `SELECT count(*) FROM users`
  - Coordinator pushes `count(*)` down to both shards in parallel and sums results.

---

## 2. Implementation Plan

### Phase 1: Reconfigure Topology for Independent Shards
- Goal: Convert nodes `pg2` and `pg3` from read-only streaming replicas into independent, standalone writable PostgreSQL instances in docker-compose.
- Tasks:
  - [ ] Update `docker-compose.yml` to remove standby entrypoints and `depends_on` replication locks for `pg2` and `pg3`.
  - [ ] Update `config/pg2/postgresql.conf` and `config/pg3/postgresql.conf` to standalone primary configurations (`hot_standby` removed, independent instances).
  - [ ] Ensure scripts `scripts/init-pg2.sh` and `scripts/init-pg3.sh` initialize standard application schemas and permissions on shard first boot.
  - [ ] Verify all 3 nodes (`pg1`, `pg2`, `pg3`) boot independently and accept writes.
- Done when: `./scripts/stop.sh && ./scripts/start.sh` boots 3 independent writable nodes; `SELECT pg_is_in_recovery()` returns `f` on all 3 nodes.

### Phase 2: Shard Schema & Foreign Data Wrapper Integration
- Goal: Install `postgres_fdw`, register foreign servers, configure user mappings, and initialize partition target tables on shards.
- Tasks:
  - [ ] Write initialization SQL script for shard nodes to create physical partition tables (`users_shard_1` on `pg2`, `users_shard_2` on `pg3`).
  - [ ] Write coordinator initialization script on `pg1`:
    - Enable `postgres_fdw`.
    - Create foreign servers `shard1_server` and `shard2_server` with network optimization options (`fetch_size '1000'`, `batch_size '1000'`).
    - Create user mappings for `postgres` user.
  - [ ] Create root partitioned table `users` on `pg1` using hash partitioning (`PARTITION BY HASH (id)`).
  - [ ] Bind foreign tables `users_p0` and `users_p1` to remote servers.
- Done when: Coordinator schema inspection shows `users` partitioned table with `users_p0` and `users_p1` foreign partitions pointing to `pg2` and `pg3`.

### Phase 3: Sharding Verification Suite
- Goal: Build an automated test script (`scripts/test-sharding.sh`) verifying transparent routing, partition isolation, partition pruning, and pushdown.
- Tasks:
  - [ ] Test 1: Direct multi-row batch insert into `users` on coordinator (`pg1`).
  - [ ] Test 2: Verify rows physically landed on `pg2` (`users_shard_1`) and `pg3` (`users_shard_2`) based on hash remainder.
  - [ ] Test 3: Confirm coordinator query returns aggregated view of all rows (`SELECT count(*) FROM users`).
  - [ ] Test 4: Run `EXPLAIN` on key lookup query (`WHERE id = X`) to assert partition pruning eliminated the non-target shard.
  - [ ] Test 5: Verify update and delete propagation across shards.
- Done when: `./scripts/test-sharding.sh` passes 100% of checks on a freshly booted cluster.

### Phase 4: Developer Documentation & Inspection Tooling
- Goal: Provide an inspection script and clear documentation for developers to query and observe shard distributions.
- Tasks:
  - [ ] Implement `scripts/inspect.sh` to output:
    - Node status and active connections.
    - Row count and table sizes per individual shard.
    - Sample rows and distribution percentages across shards.
  - [ ] Update `README.md` with sharding tutorial, architectural diagrams, quickstart commands, and query examples.
- Done when: Running `./scripts/inspect.sh` provides an immediate visual summary of shard distribution.

---

## 3. Unknowns, Risks & Assumptions

- **Assumptions**:
  - We use the existing 3 containers (`pg1` coordinator, `pg2` shard1, `pg3` shard2). No additional containers are required.
  - Distributed transactions rely on standard PostgreSQL two-phase commits (`postgres_fdw` handles 2PC if multiple foreign servers are modified in one transaction).
- **Risks**:
  - Foreign key constraints cannot reference remote foreign tables in vanilla PostgreSQL without custom triggers. (This will be documented in the tutorial section of README).
  - Global unique constraints across shards are enforced per partition by the shard itself; the coordinator enforces global uniqueness on the partition key (`id`).
