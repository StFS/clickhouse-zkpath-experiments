# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Scratch space for experimenting with [dbmate](https://github.com/amacneil/dbmate)
against ClickHouse. Currently there is no dbmate code yet — just a local
ClickHouse cluster (docker compose) and a test script exploring
`ReplicatedMergeTree` behavior. See `README.md` for the full walkthrough.

## Topology at a glance

- Cluster name: `cluster_2S_2R` — 2 shards × 2 replicas (`ch-01..ch-04`)
- 3-node Keeper quorum (`keeper-01..keeper-03`)
- HAProxy fronts all 4 ClickHouse nodes; only `8123`, `9000`, and `8404`
  (stats) are exposed on the host. Per-node ports are intentionally not
  published.
- `default_replica_path` is set to `/clickhouse/tables/{uuid}/{shard}` in
  `config/clickhouse/cluster.xml`.

## Gotchas worth remembering

- **Cluster `<secret>` is required**, not optional. In ClickHouse 26.x,
  distributed queries that go through direct node-to-node connections
  (`remote()`, `clusterAllReplicas`, `Distributed` tables) fail with
  `AUTHENTICATION_FAILED` unless `remote_servers.<cluster>.<secret>` is set.
  `ON CLUSTER` DDL is dispatched through Keeper and works without the secret,
  which makes the problem easy to miss: DDL looks healthy while SELECTs across
  replicas die. If you add a new cluster, add a `<secret>` to it.
- **Config reload after editing `config/clickhouse/*.xml`**: restart the
  ClickHouse nodes only — `docker compose restart ch-01 ch-02 ch-03 ch-04`.
  Don't bounce the keepers unless you're specifically changing their config.
- **`EXISTS TABLE ...` is a statement, not an expression.** It can't be
  embedded in `SELECT`. For per-replica checks, query `system.tables` via
  `clusterAllReplicas` instead.
- **CREATE short-circuits on name before evaluating engine args.** Both
  `CREATE TABLE` and `CREATE TABLE IF NOT EXISTS` decide based on the local
  table name alone, so you cannot exercise `default_replica_path` while a
  table by that name already exists — the engine arguments are never reached.
- **HAProxy is for external clients.** The test script (and anything
  exercising cluster behavior) should talk to a specific node via
  `docker exec -i ch-01 clickhouse-client`, not through the load balancer,
  since round-robin makes it non-deterministic which node a session hits.

## Common commands

```sh
# bring the cluster up / down
docker compose up -d
docker compose down            # keeps volumes
docker compose down -v         # wipes Keeper + ClickHouse state

# run the replicated-table test
./test-default-replica-path.sh

# query a specific node
docker exec -it ch-01 clickhouse-client -q "SELECT ..."

# query through HAProxy (round-robin)
curl -s 'http://localhost:8123/?query=SELECT+hostName()'
```
