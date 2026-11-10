#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NS="${NAMESPACE:-zabbix}"

# Only the gateways changed; avoid rebuilding apps and rolling databases.
helm upgrade --install otel-collector ./charts/otel-collector --namespace "$NS" --timeout=60s
helm upgrade --install alloy ./charts/alloy --namespace "$NS" --timeout=60s
bash ./scripts/verify-apm.sh
