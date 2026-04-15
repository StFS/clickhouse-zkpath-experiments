# clickhouse-experiments

A local ClickHouse cluster for experimenting with replication, ZooKeeper paths,
and (eventually) `dbmate` migrations against ClickHouse.

## Topology

```
                 ┌──────────┐  ┌──────────┐  ┌──────────┐
                 │ keeper-01│  │ keeper-02│  │ keeper-03│   (3-node Raft quorum)
                 └────┬─────┘  └────┬─────┘  └────┬─────┘
                      └─────────────┼─────────────┘
                                    │
         ┌──────────┬────────────── │ ──────────────┬──────────┐
         │          │               │               │          │
     ┌───┴──┐   ┌───┴──┐         ┌──┴───┐        ┌──┴───┐
     │ ch-01│   │ ch-02│         │ ch-03│        │ ch-04│
     └───┬──┘   └───┬──┘         └───┬──┘        └───┬──┘
         └───shard 01──┘             └───shard 02────┘
                │                            │
                └────────────┬───────────────┘
                             │
                         ┌───┴────┐
                         │haproxy │   8123 (HTTP) · 9000 (native) · 8404 (stats)
                         └────────┘
```

- Cluster name: `cluster_2S_2R` (2 shards × 2 replicas)
- `internal_replication=true` — writes to a `Distributed` table are sent to one
  replica per shard, which then replicates via Keeper
- Inter-server queries use a shared cluster `<secret>`, which is required in
  recent ClickHouse versions for `remote()` / `clusterAllReplicas` / `Distributed`
  fan-out (separate from `ON CLUSTER` DDL, which runs via Keeper)
- `default_replica_path` is set to `/clickhouse/tables/{uuid}/{shard}`, so
  `ReplicatedMergeTree()` with no arguments produces a UUID-scoped ZK path

## Layout

```
docker-compose.yml
config/
├── keeper/
│   ├── keeper-01.xml          # server_id=1
│   ├── keeper-02.xml          # server_id=2
│   └── keeper-03.xml          # server_id=3
├── clickhouse/
│   ├── cluster.xml            # remote_servers, zookeeper, default_replica_path
│   └── macros-ch-0{1..4}.xml  # per-node {cluster}/{shard}/{replica} macros
└── haproxy/
    └── haproxy.cfg            # round-robin over all 4 ClickHouse nodes
test-default-replica-path.sh
```

## Running

Start everything:

```sh
docker compose up -d
```

HAProxy exposes:

| Port | Protocol      | Notes                                |
| ---- | ------------- | ------------------------------------ |
| 8123 | HTTP          | round-robin over ch-01..ch-04        |
| 9000 | Native TCP    | round-robin over ch-01..ch-04        |
| 8404 | HTTP (stats)  | <http://localhost:8404/stats>        |

Quick check that the cluster is assembled:

```sh
docker exec -it ch-01 clickhouse-client -q \
  "SELECT cluster, shard_num, replica_num, host_name
   FROM system.clusters WHERE cluster='cluster_2S_2R'"
```

Or through the load balancer:

```sh
curl -s 'http://localhost:8123/?query=SELECT+hostName()'
```

Tear down (keeps volumes):

```sh
docker compose down
```

Tear down and wipe Keeper + ClickHouse state:

```sh
docker compose down -v
```

## `test-default-replica-path.sh`

Exercises what happens when you try to create a `ReplicatedMergeTree` table
twice under the same name — once with an explicit ZK path, then again with the
server-side default path.

Steps:

1. `DROP TABLE IF EXISTS default.events ON CLUSTER ... SYNC` (cleanup).
2. **Step 1** — `CREATE TABLE default.events ON CLUSTER ... ENGINE = ReplicatedMergeTree('/clickhouse/tables/{cluster}/{table}', '{replica}')`,
   then dump `zookeeper_path` / `replica_path` from
   `clusterAllReplicas(..., system.replicas)`.
3. **Step 2** — attempt the same `CREATE` with `ReplicatedMergeTree()` (no
   arguments, relying on `default_replica_path`). Expected to fail.
4. **Step 3** — same as step 2 but with `CREATE TABLE IF NOT EXISTS`. Expected
   to succeed silently.
5. **Step 4** — run `EXISTS TABLE default.events` plus a per-replica
   confirmation via `clusterAllReplicas(..., system.tables)`.
6. Dump replica state again.

Run it with:

```sh
./test-default-replica-path.sh
```

**Expected observations:**

- Step 1 registers all 4 nodes under the *same* ZK path
  (`/clickhouse/tables/cluster_2S_2R/events`) because the path doesn't include
  `{shard}` — both shards' replicas collapse into a single 4-replica set.
- Step 2 fails with `Code: 57 TABLE_ALREADY_EXISTS`. The local name check
  happens before the engine arguments are evaluated, so `default_replica_path`
  is never exercised while a table by that name exists.
- Step 3 succeeds: `IF NOT EXISTS` short-circuits on the name match and the
  statement is a no-op. The original table (with the explicit ZK path) is
  left in place.
- Step 4 returns `1` from `EXISTS TABLE`, and the per-replica check shows
  `found=1` on all four nodes.
- The existing table is unaffected by any of steps 2–4.
