#!/usr/bin/env bash
#
# Creates a ReplicatedMergeTree table with an explicit ZK path, then attempts
# to create a second table with the same name but relying on the server-side
# default_replica_path (/clickhouse/tables/{uuid}/{shard}).
#
set -euo pipefail

CLIENT=(docker exec -i ch-01 clickhouse-client)
CLUSTER="cluster_2S_2R"
DB="default"
TABLE="events"

run() { "${CLIENT[@]}" "$@"; }

hr() { printf '\n=== %s ===\n' "$1"; }

hr "Cleanup: drop any previous instance of ${DB}.${TABLE}"
run -q "DROP TABLE IF EXISTS ${DB}.${TABLE} ON CLUSTER ${CLUSTER} SYNC"

hr "Step 1: CREATE with explicit ZK path"
run --multiquery <<SQL
CREATE TABLE ${DB}.${TABLE} ON CLUSTER ${CLUSTER}
(
    ts    DateTime,
    id    UInt64,
    value String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{cluster}/{table}', '{replica}')
ORDER BY ts;
SQL

hr "ZK paths registered by step 1"
run -q "
SELECT database, table, replica_name, zookeeper_path, replica_path
FROM clusterAllReplicas('${CLUSTER}', system.replicas)
WHERE database='${DB}' AND table='${TABLE}'
FORMAT Vertical
"

hr "Step 2: CREATE same table with default ZK path (ReplicatedMergeTree() — no args)"
set +e
run --multiquery <<SQL
CREATE TABLE ${DB}.${TABLE} ON CLUSTER ${CLUSTER}
(
    ts    DateTime,
    id    UInt64,
    value String
)
ENGINE = ReplicatedMergeTree()
ORDER BY ts;
SQL
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
    echo ">>> Second CREATE succeeded"
else
    echo ">>> Second CREATE failed with exit code $rc (table already exists on the cluster)"
fi

hr "Step 3: CREATE IF NOT EXISTS with default ZK path"
run --multiquery <<SQL
CREATE TABLE IF NOT EXISTS ${DB}.${TABLE} ON CLUSTER ${CLUSTER}
(
    ts    DateTime,
    id    UInt64,
    value String
)
ENGINE = ReplicatedMergeTree()
ORDER BY ts;
SQL
echo ">>> Step 3 completed without error"

hr "Step 4: EXISTS TABLE ${DB}.${TABLE}"
run -q "EXISTS TABLE ${DB}.${TABLE}"
echo ">>> (1 = found, 0 = not found)"

hr "Step 4b: Per-replica confirmation via system.tables"
run -q "
SELECT hostName() AS host, count() AS found
FROM clusterAllReplicas('${CLUSTER}', system.tables)
WHERE database='${DB}' AND name='${TABLE}'
GROUP BY host
ORDER BY host
FORMAT PrettyCompactMonoBlock
"

hr "Final state of ${DB}.${TABLE}"
run -q "
SELECT database, table, replica_name, zookeeper_path, replica_path
FROM clusterAllReplicas('${CLUSTER}', system.replicas)
WHERE database='${DB}' AND table='${TABLE}'
FORMAT Vertical
"
