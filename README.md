# PostgreSQL 18 — 3-Way Hybrid Sharding Cluster (Docker Compose)

Native horizontal sharding across three PostgreSQL 18 nodes using **Declarative Table Partitioning** and **Foreign Data Wrappers (`postgres_fdw`)** in a **3-Way Hybrid Architecture** (where every node stores a third of the dataset).

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

### Node Roles

| Container | Role | Port | Storage Type | Partition Key Route |
|-----------|------|------|--------------|---------------------|
| `pg1` | **Coordinator & Shard 0** | `5432` | **Local Disk Table** (`users_p0`) | `hash(id) % 3 = 0` |
| `pg2` | **Data Shard 1** | `5433` | **Remote Foreign Table** (`users_shard_1`) | `hash(id) % 3 = 1` |
| `pg3` | **Data Shard 2** | `5434` | **Remote Foreign Table** (`users_shard_2`) | `hash(id) % 3 = 2` |

---

## 2. How Hybrid Sharding Works

### Step 1: Remote Shard Physical Tables
`pg2` and `pg3` host their respective physical partition tables:
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

### Step 2: Foreign Data Wrapper on Coordinator (`pg1`)
The coordinator uses `postgres_fdw` to communicate with the remote shard containers:
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

### Step 3: Hybrid Partitioning (1 Local Partition + 2 Foreign Partitions)
On `pg1`, we define a root partitioned table using `MODULUS 3`. Partition 0 is created as a **local table on `pg1`**, while partitions 1 and 2 are attached as **foreign tables**:
```sql
-- Root partitioned table on Coordinator
CREATE TABLE users (
    id BIGINT NOT NULL,
    username TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
) PARTITION BY HASH (id);

-- 1. LOCAL partition stored on pg1's disk:
CREATE TABLE users_p0
    PARTITION OF users
    FOR VALUES WITH (MODULUS 3, REMAINDER 0);

CREATE INDEX users_p0_id_idx ON users_p0 (id);

-- 2. REMOTE partition on pg2 (Shard 1):
CREATE FOREIGN TABLE users_p1
    PARTITION OF users
    FOR VALUES WITH (MODULUS 3, REMAINDER 1)
    SERVER shard1_server
    OPTIONS (table_name 'users_shard_1');

-- 3. REMOTE partition on pg3 (Shard 2):
CREATE FOREIGN TABLE users_p2
    PARTITION OF users
    FOR VALUES WITH (MODULUS 3, REMAINDER 2)
    SERVER shard2_server
    OPTIONS (table_name 'users_shard_2');
```

### Step 4: Transparent Routing & Query Planning
- **Inserts**: Inserting through `pg1` calculates `hash(id) % 3`. If remainder is `0`, it writes to `pg1`'s local table. If `1` or `2`, it forwards the row across the network to `pg2` or `pg3`.
- **Partition Pruning**:
  - `WHERE id = 2` (remainder 0) -> Scans local index on `users_p0` and **prunes both remote shards**:
    ```
    Bitmap Heap Scan on users_p0 users
      -> Bitmap Index Scan on users_p0_id_idx
    ```
  - `WHERE id = 3` (remainder 1) -> Emits `Foreign Scan on users_p1` to `pg2` and **prunes `pg1` and `pg3`**.

---

## 3. Directory Layout

```
.
├── config/
│   ├── pg1/               # Coordinator & Shard 0 config
│   ├── pg2/               # Shard 1 config
│   └── pg3/               # Shard 2 config
├── scripts/
│   ├── init-pg1.sh        # Configures postgres_fdw, local partition users_p0, and foreign partitions
│   ├── init-pg2.sh        # Creates users_shard_1 table on Shard 1
│   ├── init-pg3.sh        # Creates users_shard_2 table on Shard 2
│   ├── start.sh           # Starts the cluster (pg2/pg3 healthy -> pg1 coordinator)
│   ├── stop.sh            # Stops cluster and wipes containers + volumes
│   ├── seed.sh            # Inserts sample rows with 3-way distribution summary
│   ├── test-sharding.sh   # 17-check automated hybrid sharding test suite
│   └── inspect.sh         # Real-time cluster inspection tool
├── docker-compose.yml
├── PLAN-hybrid.md         # Hybrid implementation plan
└── .env                   # Credentials (git-ignored)
```

---

## 4. Quick Start

### 1. Start the cluster

```bash
./scripts/start.sh
```

### 2. Seed sample data

```bash
# Seed 15 rows (evenly distributed across pg1, pg2, pg3)
./scripts/seed.sh 15
```

Output:
```
Current Distribution (3-Way Hybrid):
  Local Shard 0 (pg1 users_p0):       5 rows
  Remote Shard 1 (pg2 users_shard_1): 5 rows
  Remote Shard 2 (pg3 users_shard_2): 5 rows
  Total:                              15 rows across cluster
```

### 3. Run the automated verification suite

```bash
./scripts/test-sharding.sh
```

Verifies:
1. Node connectivity across all 3 nodes.
2. Catalog checks: 1 local partition + 2 foreign partitions.
3. Distributed batch inserts across local and remote shards.
4. Physical row placement across all 3 nodes.
5. Unified aggregation queries (`SELECT count(*) FROM users`).
6. Query planner partition pruning (local scans vs foreign scans).
7. Distributed `UPDATE` propagation (local and remote).
8. Distributed `DELETE` propagation (local and remote).

### 4. Inspect the cluster

```bash
./scripts/inspect.sh
```

Displays:
- Full cluster topology.
- Storage type per partition (`LOCAL TABLE` on `pg1` vs `FOREIGN TABLE` on `pg2`/`pg3`).
- Row counts and disk size for each physical partition.
- Sample records previewed directly from each respective node.
- Real-time `EXPLAIN` query plans demonstrating local and remote partition pruning.

### 5. Tear down

```bash
./scripts/stop.sh
```
