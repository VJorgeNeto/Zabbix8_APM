#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
REQUESTS="${REQUESTS:-20}"

request() {
  curl -fsS -o /dev/null -w '%{http_code}\n' "$@" || true
}

echo "[1/4] health baseline"
for _ in $(seq 1 5); do request "$BASE_URL/health"; done

echo "[2/4] slow dependency: distributed trace + latency"
for _ in $(seq 1 "$REQUESTS"); do request "$BASE_URL/external-api?scenario=slow"; done

echo "[3/4] failing dependency: downstream 503 -> upstream 502"
for _ in $(seq 1 "$REQUESTS"); do request "$BASE_URL/external-api?scenario=error"; done

echo "[4/4] application errors and CPU pressure"
for _ in $(seq 1 "$REQUESTS"); do request "$BASE_URL/random-failure"; done
for _ in $(seq 1 3); do request -X POST "$BASE_URL/load-test/cpu-spike"; done

echo "Demo traffic generated. Use the Zabbix APM views to inspect the traces."
