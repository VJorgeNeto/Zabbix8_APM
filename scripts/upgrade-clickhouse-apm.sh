#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NS="${NAMESPACE:-zabbix}"
trap 'bash "$ROOT_DIR/scripts/check-clickhouse-upgrade.sh" --diagnose-only || true' ERR

python3 scripts/backup-apm.py
helm upgrade zabbix-apm ./charts/zabbix-apm -n "$NS" --reuse-values \
  --set-string images.clickhouse.tag=25.8 --timeout=60s
kubectl -n "$NS" rollout status statefulset/zabbix-proxy-clickhouse --timeout=120s
echo '== versão do ClickHouse após atualização =='
kubectl -n "$NS" exec zabbix-proxy-clickhouse-0 -- sh -c \
  'exec clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "SELECT version()"'
bash scripts/verify-apm-api.sh
