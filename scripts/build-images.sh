#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-zabbix}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker build -t chaos-app:dev-v2 -f "$ROOT_DIR/apps/chaos-ap/docker/Dockerfile" "$ROOT_DIR/apps/chaos-ap"
docker build -t dependency-api:dev-v2 -f "$ROOT_DIR/apps/dependency-api/Dockerfile" "$ROOT_DIR/apps/dependency-api"

kind load docker-image chaos-app:dev-v2 --name "$CLUSTER_NAME"
kind load docker-image dependency-api:dev-v2 --name "$CLUSTER_NAME"
