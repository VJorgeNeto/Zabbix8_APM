#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-zabbix}"

diagnostics() {
  echo '== diagnóstico da falha (últimas linhas) ==' >&2
  kubectl -n "$NS" get pods >&2 || true
  for component in otel-collector alloy; do
    kubectl -n "$NS" logs "deployment/$component" --tail=35 >&2 || true
  done
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -12 >&2 || true
}
trap diagnostics ERR

for component in otel-collector alloy chaos-app dependency-api; do
  kubectl -n "$NS" rollout status "deployment/$component" --timeout=60s
done
kubectl -n "$NS" rollout status statefulset/zabbix-proxy-clickhouse --timeout=60s

# Read credentials inside ClickHouse, without printing them.
query() {
  kubectl -n "$NS" exec -i zabbix-proxy-clickhouse-0 -- sh -c '
    wget -qO- --timeout=10 \
      --header "X-ClickHouse-User: $CLICKHOUSE_USER" \
      --header "X-ClickHouse-Key: $CLICKHOUSE_PASSWORD" \
      --post-file=/dev/stdin "http://localhost:8123/?database=$CLICKHOUSE_DB"
  ' <<< "$1"
}

echo '== configuração esperada =='
kubectl -n "$NS" get deployment otel-collector alloy \
  -o 'custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.metadata.annotations.checksum/config'

APP_POD="$(kubectl -n "$NS" get pods -l app.kubernetes.io/instance=chaos-app \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | head -1)"
test -n "$APP_POD"

echo '== novo teste OTLP: trace + métrica + log correlacionados =='
PROBE="$(kubectl -n "$NS" exec -i "$APP_POD" -c chaos-app -- python - < "$ROOT_DIR/scripts/apm-smoke.py")"
RUN_ID="$(printf '%s' "$PROBE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')"
TRACE_ID="$(printf '%s' "$PROBE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["trace_id"])')"
[[ "$RUN_ID" =~ ^[0-9a-f]{32}$ && "$TRACE_ID" =~ ^[0-9a-f]{32}$ ]]
printf 'run_id=%s trace_id=%s\n' "$RUN_ID" "$TRACE_ID"

# Exercise the real instrumented app as well as the isolated SDK probe.
kubectl -n "$NS" exec "$APP_POD" -c chaos-app -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/external-api?scenario=healthy', timeout=15).read().decode())"

echo '== aguardando persistência deste teste (até 15 consultas) =='
SQL="SELECT
 (SELECT count() FROM otel_traces WHERE TraceId='$TRACE_ID'),
 (SELECT count() FROM otel_metrics_sum WHERE ResourceAttributes['demo.run_id']='$RUN_ID'),
 (SELECT count() FROM otel_logs WHERE TraceId='$TRACE_ID') FORMAT TabSeparated"
for attempt in {1..15}; do
  COUNTS="$(query "$SQL")"
  read -r TRACES METRICS LOGS <<< "$COUNTS"
  printf 'traces=%s metrics=%s logs=%s\n' "$TRACES" "$METRICS" "$LOGS"
  if (( TRACES > 0 && METRICS > 0 && LOGS > 0 )); then
    echo 'APM_OK: os três sinais deste teste foram encontrados no ClickHouse.'
    echo 'Frontend: APM → Traces/Logs, serviço apm-smoke; filtre pelo trace_id acima.'
    exit 0
  fi
  sleep 2
done
echo 'APM_FALHOU: não houve persistência dos três sinais; SUCCESS no SDK não comprova armazenamento.' >&2
diagnostics
exit 1
