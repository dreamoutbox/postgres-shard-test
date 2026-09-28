# PostgreSQL 18 — Horizontal Sharding Cluster (Docker Compose)

Native horizontal sharding across three PostgreSQL 18 nodes using **Declarative Table Partitioning** and **Foreign Data Wrappers (`postgres_fdw`)**.

---

## 1. Architecture Overview

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

### Node Roles

| Container | Role | Port | Description |
|-----------|------|------|-------------|
| `pg1` | **Coordinator** | `5432` | Entry point for client queries. Holds the partitioned table definition and foreign server links. Holds **0 rows locally**. |
| `pg2` | **Data Shard 1** | `5433` | Standalone PostgreSQL instance holding physical partition `users_shard_1` (`hash % 2 = 0`). |
| `pg3` | **Data Shard 2** | `5434` | Standalone PostgreSQL instance holding physical partition `users_shard_2` (`hash % 2 = 1`). |

---

## 2. How PostgreSQL Native Sharding Works

### Step 1: Physical Tables on Remote Shards
Each data shard is an autonomous database hosting its designated partition table:
```sql
-- On pg2 (Shard 1):
CREATE TABLE users_shard_1 (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT users_shard_1_pkey PRIMARY KEY (id)
);

-- On pg3 (Shard 2):
CREATE TABLE users_shard_2 (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT users_shard_2_pkey PRIMARY KEY (id)
);
```

### Step 2: Foreign Data Wrapper on Coordinator
The coordinator uses `postgres_fdw` to communicate with the shard containers:
```sql
-- On pg1 (Coordinator):
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

CREATE SERVER shard1_server FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg2', port '5432', dbname 'appdb', fetch_size '1000', batch_size '1000');

CREATE SERVER shard2_server FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'pg3', port '5432', dbname 'appdb', fetch_size '1000', batch_size '1000');

CREATE USER MAPPING FOR postgres SERVER shard1_server
    OPTIONS (user 'postgres', password 'postgres');

CREATE USER MAPPING FOR postgres SERVER shard2_server
    OPTIONS (user 'postgres', password 'postgres');
```

### Step 3: Declarative Partitioning Attached to Foreign Tables
On `pg1`, we define a root partitioned table and attach foreign tables as partitions:
```sql
-- Root partitioned table on Coordinator (stores no data locally)
-- Note: Foreign partitions cannot have UNIQUE/PRIMARY KEY constraints on the root table.
CREATE TABLE users (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
) PARTITION BY HASH (id);

-- Partition 0 mapped to Shard 1
CREATE FOREIGN TABLE users_p0
    PARTITION OF users
    FOR VALUES WITH (MODULUS 2, REMAINDER 0)
    SERVER shard1_server
    OPTIONS (table_name 'users_shard_1');

-- Partition 1 mapped to Shard 2
CREATE FOREIGN TABLE users_p1
    PARTITION OF users
    FOR VALUES WITH (MODULUS 2, REMAINDER 1)
    SERVER shard2_server
    OPTIONS (table_name 'users_shard_2');
```

### Step 4: Transparent Query Execution & Partition Pruning
- **Inserts**: An insert into `users` on the coordinator hashes `id` and forwards the row over network to either `pg2` or `pg3`.
- **Partition Pruning**: Querying `WHERE id = 1` evaluates the hash remainder; Postgres automatically skips communicating with non-target shards:
  ```sql
  EXPLAIN (COSTS OFF) SELECT * FROM users WHERE id = 1;
  -- Output:
  -- Foreign Scan on users_p0 users
  -- (users_p1 is pruned!)
  ```
- **Aggregate Pushdown**: Queries like `count(*)` or `sum()` are pushed down to shard nodes to compute in parallel.

---

## 3. Directory Layout

```
.
├── config/
│   ├── pg1/               # Coordinator config (max_prepared_transactions for 2PC)
│   ├── pg2/               # Shard 1 config
│   └── pg3/               # Shard 2 config
├── scripts/
│   ├── init-pg1.sh        # Sets up postgres_fdw, foreign servers, and foreign partitions
│   ├── init-pg2.sh        # Creates users_shard_1 table on Shard 1
│   ├── init-pg3.sh        # Creates users_shard_2 table on Shard 2
│   ├── start.sh           # Starts the cluster (pg2/pg3 healthy -> pg1 coordinator)
│   ├── stop.sh            # Stops cluster and wipes containers + volumes
│   ├── test-sharding.sh   # 13-check automated sharding test suite
│   └── inspect.sh         # Real-time cluster inspection tool
├── docker-compose.yml
├── PLAN.md                # Implementation plan & tutorial
└── .env                   # Credentials (git-ignored)
```

---

## 4. Quick Start

### 1. Start the cluster

```bash
./scripts/start.sh
```

### 2. Run the automated verification suite

```bash
./scripts/test-sharding.sh
```

Tests:
1. Node connectivity across coordinator and both shards.
2. Foreign server and foreign partition catalog checks.
3. Distributed batch insert on coordinator.
4. Physical shard distribution validation (rows land across `users_shard_1` and `users_shard_2`).
5. Unified aggregation queries (`SELECT count(*) FROM users`).
6. Query planner partition pruning (`EXPLAIN` key lookup prunes non-target shard).
7. Distributed `UPDATE` propagation.
8. Distributed `DELETE` propagation.

### 3. Inspect the cluster

```bash
./scripts/inspect.sh
```

Shows cluster topology, foreign partition bindings, row count and disk size per shard, and sample data.

### 4. Interactive queries

Connect to the coordinator (`pg1`):
```bash
docker exec -it pg1 psql -U postgres -d appdb
```

Insert rows and observe transparent routing:
```sql
INSERT INTO users (id, username, email) VALUES
    (1, 'alice', 'alice@example.com'),
    (2, 'bob', 'bob@example.com'),
    (3, 'carol', 'carol@example.com');

-- Unified view from Coordinator:
SELECT * FROM users;

-- Observe partition pruning:
EXPLAIN SELECT * FROM users WHERE id = 1;
```

Verify rows on the physical shards directly:
```bash
# Shard 1:
docker exec -it pg2 psql -U postgres -d appdb -c "SELECT * FROM users_shard_1;"

# Shard 2:
docker exec -it pg3 psql -U postgres -d appdb -c "SELECT * FROM users_shard_2;"
```

### 5. Tear down

```bash
./scripts/stop.sh
```
