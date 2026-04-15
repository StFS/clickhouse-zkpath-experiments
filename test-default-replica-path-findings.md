# Report: `ReplicatedMergeTree` default-path behavior

**Environment:** ClickHouse 26.3.9.8, cluster `cluster_2S_2R` (2 shards × 2 replicas), 3-node Keeper quorum, `default_replica_path = /clickhouse/tables/{uuid}/{shard}` configured server-side. Run against a freshly started compose stack.

## Findings per step

### Step 1 — explicit ZK path ✓

`CREATE TABLE default.events ON CLUSTER cluster_2S_2R ENGINE = ReplicatedMergeTree('/clickhouse/tables/{cluster}/{table}', '{replica}')` succeeded on all four nodes. `system.replicas` confirms:

| replica | `zookeeper_path`                          | `replica_path`                                         |
|---------|-------------------------------------------|--------------------------------------------------------|
| ch-01   | `/clickhouse/tables/cluster_2S_2R/events` | `/clickhouse/tables/cluster_2S_2R/events/replicas/ch-01` |
| ch-02   | `/clickhouse/tables/cluster_2S_2R/events` | `/clickhouse/tables/cluster_2S_2R/events/replicas/ch-02` |
| ch-03   | `/clickhouse/tables/cluster_2S_2R/events` | `/clickhouse/tables/cluster_2S_2R/events/replicas/ch-03` |
| ch-04   | `/clickhouse/tables/cluster_2S_2R/events` | `/clickhouse/tables/cluster_2S_2R/events/replicas/ch-04` |

**Interpretation:** `{cluster}` and `{table}` expand, but `{shard}` is absent from the path, so *all four* replicas land on the same ZK znode and appear as a single 4-replica set to Keeper. Whatever sharding the cluster config defines (2 shards) is irrelevant at the Keeper level for this table — both shards write to the same replicated log. That's a valid configuration but usually not what you want in production; it happens to surface here because the macro template `{cluster}/{table}` doesn't include `{shard}`.

### Step 2 — bare `ReplicatedMergeTree()` over an existing table ✗ (expected)

Every node returned `Code: 57 TABLE_ALREADY_EXISTS` and the `ON CLUSTER` command aborted overall. Notably, the error comes from the local catalog lookup on `default.events`; ClickHouse never got far enough to evaluate the engine arguments, which means **`default_replica_path` is never consulted in this scenario**. The existing step-1 table is untouched.

### Step 3 — `CREATE TABLE IF NOT EXISTS` with bare engine ✓

Succeeded silently on all four nodes, no error. But this success is slightly misleading: `IF NOT EXISTS` short-circuits on the name match before the engine is parsed, so again **`default_replica_path` is never reached**. The query is effectively a no-op. If you read the output naively you might think ClickHouse "merged" or "reconciled" two definitions — it didn't. The original explicit-path table is still the live one.

### Step 4 — name lookup ✓

- `EXISTS TABLE default.events` → `1`
- Per-replica `clusterAllReplicas(..., system.tables)` → `found=1` on ch-01, ch-02, ch-03, ch-04

All replicas agree the table exists under the expected name. The final `system.replicas` dump matches step 1 byte-for-byte — no ZK path rewrite happened anywhere in steps 2–4.

## Key takeaways

1. **CREATE is a name-first operation.** Both plain `CREATE` and `CREATE IF NOT EXISTS` decide their fate on the local table name alone. Engine arguments (including whether the path is explicit or defaulted) are not part of the conflict check, which also means you cannot use them to "migrate" a table in place — you must `DROP` and recreate.
2. **`default_replica_path` was not exercised in this run**, despite being configured. To actually see a `{uuid}/{shard}` path, drop the table first, then create with `ReplicatedMergeTree()`. The step-3 success is an idempotency guarantee, not evidence that the new default path works.
3. **Macro hygiene matters more than the default path setting.** The step-1 template `/clickhouse/tables/{cluster}/{table}` silently collapses two shards into one replication group. If a migration tool (dbmate, etc.) were to blindly accept user-provided ZK paths, it would be easy to produce this footgun without any error. The `{uuid}/{shard}` default sidesteps this by always including `{shard}`.
4. **Implication for dbmate-style migrations:** a migration that says "create this replicated table if it's not already there" is safe to re-run (step 3 proves it), but it cannot be used to *change* a replicated table's ZK path — that requires an explicit drop. Worth keeping in mind when designing the migration workflow this repo is leading toward.
