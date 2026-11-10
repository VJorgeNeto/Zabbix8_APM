#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NAMESPACE:-zabbix}"
POD=zabbix-proxy-clickhouse-0

echo '== estado do ClickHouse =='
kubectl -n "$NS" get pod "$POD" -o wide --request-timeout=10s
kubectl -n "$NS" get pod "$POD" --request-timeout=10s -o 'jsonpath=Image: {.spec.containers[0].image}{"\n"}Current: {.status.containerStatuses[0].state}{"\n"}Previous: {.status.containerStatuses[0].lastState}{"\n"}'

READY="$(kubectl -n "$NS" get pod "$POD" --request-timeout=10s -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$READY" == True && "${1:-}" != --diagnose-only ]]; then
  echo '== ClickHouse pronto; versão e consulta filtrada =='
  kubectl -n "$NS" exec "$POD" -- sh -c \
    'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT version()"'
  if ! bash "$ROOT_DIR/scripts/verify-apm-api.sh"; then
    echo '== Service e endpoints usados pelo DNS =='
    kubectl -n "$NS" get service zabbix-proxy-clickhouse -o wide
    kubectl -n "$NS" get endpoints zabbix-proxy-clickhouse -o wide
    exit 1
  fi
  exit 0
fi

echo '== eventos do pod =='
kubectl -n "$NS" get events --field-selector "involvedObject.name=$POD" \
  --sort-by=.lastTimestamp --request-timeout=10s | tail -15 || true
echo '== logs da inicialização atual =='
kubectl -n "$NS" logs "$POD" -c clickhouse --tail=70 --request-timeout=10s || true
echo '== logs da inicialização anterior =='
kubectl -n "$NS" logs "$POD" -c clickhouse --previous --tail=40 --request-timeout=10s || true
echo '== arquivo de erros do ClickHouse, se o container permitir exec =='
kubectl -n "$NS" exec "$POD" -c clickhouse -- sh -c \
  'test ! -r /var/log/clickhouse-server/clickhouse-server.err.log || tail -40 /var/log/clickhouse-server/clickhouse-server.err.log' || true
if [[ "$READY" != True ]]; then
  echo 'ClickHouse ainda não está pronto; os eventos e logs acima mostram a causa.' >&2
  exit 1
fi
