#!/usr/bin/env bash
set -euo pipefail
NS="${NAMESPACE:-zabbix}"
DIAG_POD="clickhouse-image-check-$(date +%s)-$$"
IMAGE=clickhouse/clickhouse-server:26.8.36.3-alpine
cleanup() {
  kubectl -n "$NS" delete pod "$DIAG_POD" --ignore-not-found --wait=false >/dev/null || true
}
trap cleanup EXIT

# Fresh image only: no PVC, database files or credentials are mounted.
kubectl -n "$NS" run "$DIAG_POD" --image="$IMAGE" --image-pull-policy=IfNotPresent \
  --restart=Never --command -- /bin/bash -c '
    set +e
    echo "== entrypoint original, linha que falhou =="
    nl -ba /entrypoint.sh | sed -n "245,265p"
    echo "== kernel =="
    uname -r
    echo "== versão do binário =="
    timeout 15 clickhouse --version
    printf "version_exit=%s\n" "$?"
    echo "== extração do path, com stderr visível =="
    timeout 15 clickhouse extract-from-config --config-file /etc/clickhouse-server/config.xml --key path
    printf "extract_exit=%s\n" "$?"
    echo "== configuração de diretório =="
    grep -n -E "<path>|<tmp_path>|<user_files_path>" /etc/clickhouse-server/config.xml
    echo "== bibliotecas =="
    ldd /usr/bin/clickhouse 2>&1 | head -12
    exit 0
  '
kubectl -n "$NS" logs -f "$DIAG_POD" --pod-running-timeout=45s
