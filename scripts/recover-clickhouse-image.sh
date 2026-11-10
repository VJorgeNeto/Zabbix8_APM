#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NS="${NAMESPACE:-zabbix}"
IMAGE=clickhouse/clickhouse-server:25.8
TEST_POD="clickhouse-glibc-check-$(date +%s)-$$"
cleanup() {
  kubectl -n "$NS" delete pod "$TEST_POD" --ignore-not-found --wait=false >/dev/null || true
}
trap cleanup EXIT

CURRENT_IMAGE="$(kubectl -n "$NS" get statefulset zabbix-proxy-clickhouse -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "$CURRENT_IMAGE" == clickhouse/clickhouse-server:26.8.36.3* ]]; then
  # Both 26.8 variants were proven to fail before opening the data directory.
  # Restore the last working image first; never downgrade an already-running 25.8.
  echo '== restaurando 24.8 que funcionava; 26.8 não chegou a abrir o banco =='
  helm upgrade zabbix-apm ./charts/zabbix-apm -n "$NS" --reuse-values \
    --set-string images.clickhouse.tag=24.8-alpine --timeout=60s
fi

DESIRED_IMAGE="$(kubectl -n "$NS" get statefulset zabbix-proxy-clickhouse -o jsonpath='{.spec.template.spec.containers[0].image}')"
POD_IMAGE="$(kubectl -n "$NS" get pod zabbix-proxy-clickhouse-0 -o jsonpath='{.spec.containers[0].image}')"
printf 'Template: %s\nPod atual: %s\n' "$DESIRED_IMAGE" "$POD_IMAGE"
if [[ "$DESIRED_IMAGE" == clickhouse/clickhouse-server:24.8-alpine && "$POD_IMAGE" == clickhouse/clickhouse-server:26.8.36.3* ]]; then
  OWNER="$(kubectl -n "$NS" get pod zabbix-proxy-clickhouse-0 -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')"
  [[ "$OWNER" == StatefulSet/zabbix-proxy-clickhouse ]]
  # StatefulSet rollback can wait forever for the broken old pod to become
  # ready. Recreate that exact pod after the template has been reverted.
  echo '== recriando apenas o pod quebrado 26.8; PVCs preservados =='
  kubectl -n "$NS" delete pod zabbix-proxy-clickhouse-0 --wait=true --timeout=30s
fi
if ! kubectl -n "$NS" rollout status statefulset/zabbix-proxy-clickhouse --timeout=60s; then
  bash scripts/check-clickhouse-upgrade.sh --diagnose-only || true
  exit 1
fi

NODE="$(kubectl -n "$NS" get pod zabbix-proxy-clickhouse-0 -o jsonpath='{.spec.nodeName}')"
[[ "$NODE" =~ ^[a-zA-Z0-9.-]+$ ]]
echo '== teste de compatibilidade 25.8 no mesmo nó, sem volumes =='
kubectl -n "$NS" run "$TEST_POD" --restart=Never --image="$IMAGE" \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\"}}" --command -- /bin/bash -ec '
    ulimit -c 0
    echo "== CPU e kernel =="
    uname -m
    grep -m1 -E "model name|flags|Features" /proc/cpuinfo || true
    clickhouse --version
    echo "== teste da subconsulta correlacionada =="
    clickhouse local --query "SELECT count() FROM numbers(2) t WHERE EXISTS (SELECT 1 FROM numbers(2) tf WHERE tf.number = t.number)"
    data_path=$(clickhouse extract-from-config --config-file /etc/clickhouse-server/config.xml --key path)
    test "$data_path" = /var/lib/clickhouse/
    printf "CONFIG_PATH_OK=%s\n" "$data_path"
  '

phase=""
for attempt in {1..90}; do
  phase="$(kubectl -n "$NS" get pod "$TEST_POD" -o jsonpath='{.status.phase}')"
  if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then break; fi
  if (( attempt % 10 == 0 )); then printf 'Teste da imagem: %s\n' "$phase"; fi
  sleep 1
done
kubectl -n "$NS" logs "$TEST_POD" || true
if [[ "$phase" != Succeeded ]]; then
  kubectl -n "$NS" get events --field-selector "involvedObject.name=$TEST_POD" --sort-by=.lastTimestamp | tail -10
  echo 'Imagem não passou no teste; StatefulSet e volumes não foram alterados.' >&2
  exit 1
fi

echo '== imagem validada; aplicando ao ClickHouse existente =='
helm upgrade zabbix-apm ./charts/zabbix-apm -n "$NS" --reuse-values \
  --set-string images.clickhouse.tag=25.8 --timeout=60s
if ! kubectl -n "$NS" rollout status statefulset/zabbix-proxy-clickhouse --timeout=90s; then
  bash scripts/check-clickhouse-upgrade.sh --diagnose-only || true
  exit 1
fi
bash scripts/check-clickhouse-upgrade.sh
