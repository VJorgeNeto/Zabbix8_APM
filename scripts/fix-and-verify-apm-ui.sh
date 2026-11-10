#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NS="${NAMESPACE:-zabbix}"

helm upgrade zabbix ./charts/zabbix -n "$NS" --reuse-values \
  --set web.apmCurlCloseCompat=true --timeout=60s
kubectl -n "$NS" rollout status deployment/zabbix-web --timeout=90s

api_status=0
bash scripts/verify-apm-api.sh || api_status=$?

echo '== consultas recentes que falharam no ClickHouse =='
kubectl -n "$NS" exec -i zabbix-proxy-clickhouse-0 -- sh -c '
  wget -qO- -T 15 \
    --header "X-ClickHouse-User: $CLICKHOUSE_USER" \
    --header "X-ClickHouse-Key: $CLICKHOUSE_PASSWORD" \
    --post-file=/dev/stdin "http://localhost:8123/?database=$CLICKHOUSE_DB"
' <<'SQL'
SELECT event_time, exception_code, exception, query
FROM system.query_log
WHERE event_time > now() - INTERVAL 20 MINUTE
AND type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
AND (query ILIKE '%otel_traces%' OR query ILIKE '%otel_logs%' OR query ILIKE '%otel_metrics%')
ORDER BY event_time DESC LIMIT 3 FORMAT JSONEachRow
SQL

echo '== erros HTTP recentes no ClickHouse (inclusive falhas não registradas em query_log) =='
kubectl -n "$NS" logs zabbix-proxy-clickhouse-0 --since=5m --tail=150 | \
  grep -iE 'exception|unknown.identifier|unknown.table|authentication|denied|error' | tail -15 || true
exit "$api_status"
