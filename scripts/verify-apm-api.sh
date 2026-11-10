#!/usr/bin/env bash
set -euo pipefail
NS="${NAMESPACE:-zabbix}"
echo '== API APM do frontend, últimas 24h, sem filtros =='
# A single attempt using the documented lab account; no password guessing.
# This queries Zabbix itself, rather than bypassing it to query ClickHouse.
kubectl -n "$NS" exec -i deployment/chaos-app -c chaos-app -- python - <<'PY'
import json
import os
import sys
import time
import urllib.request

url = "http://zabbix-web:8080/api_jsonrpc.php"
token = os.environ.get("ZABBIX_API_TOKEN")
session_created = False

def call(method, params):
    headers = {"Content-Type": "application/json-rpc"}
    if token:
        headers["Authorization"] = "Bearer " + token
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    deadline = time.monotonic() + 60
    retries = 0
    while True:
        req = urllib.request.Request(url, data=payload, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as response:
            result = json.load(response)
        if "error" not in result:
            return result["result"]
        error = json.dumps(result["error"], ensure_ascii=False)
        # A headless Service has no DNS record while its only pod is unready.
        # CoreDNS may cache that negative response after the new pod is ready.
        if "Could not resolve hostname" in error and time.monotonic() < deadline:
            retries += 1
            print("Aguardando atualização DNS do ClickHouse (%d)..." % retries, flush=True)
            time.sleep(3)
            continue
        raise RuntimeError(error)

try:
    print("Zabbix API version:", call("apiinfo.version", {}), flush=True)
    if not token:
        token = call("user.login", {
            "username": os.environ.get("ZABBIX_USER", "Admin"),
            "password": os.environ.get("ZABBIX_PASSWORD", "zabbix"),
        })
        session_created = True
    now = int(time.time())
    params = {"time_from": now - 86400, "time_till": now + 60}
    count = call("apmtrace.get", {**params, "countOutput": True})
    print("Traces visíveis pela API Zabbix:", count, flush=True)
    rows = call("apmtrace.get", {
        **params,
        "output": "extend",
        "sortfield": "timestamp", "sortorder": "DESC", "limit": 3,
    })
    print(json.dumps(rows, indent=2, ensure_ascii=False), flush=True)
    print("== consulta com contadores usados na tela ==", flush=True)
    summary = call("apmtrace.get", {
        **params,
        "output": ["timestamp", "traceid", "service_name", "span_name", "duration", "status_code", "span_count", "error_count"],
        "sortfield": "timestamp", "sortorder": "DESC", "limit": 3,
    })
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)
    if rows:
        print("== filtro por Trace ID (consulta que falhava na tela) ==", flush=True)
        filtered = call("apmtrace.get", {
            **params,
            "traceids": [rows[0]["traceid"]],
            "output": ["traceid", "service_name", "span_count"],
            "limit": 3,
        })
        if not filtered:
            raise RuntimeError("O trace consultado sem filtro não foi retornado pelo filtro de Trace ID")
        print(json.dumps(filtered, indent=2, ensure_ascii=False), flush=True)
    if rows:
        print("FRONTEND_API_OK: consultas completas e filtro de Trace ID funcionaram no Zabbix.")
    else:
        print("FRONTEND_API_VAZIA: ClickHouse tem dados, mas a consulta APM do Zabbix não os retornou.")
        sys.exit(1)
except Exception as exc:
    print("FRONTEND_API_ERRO:", str(exc), file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    if session_created:
        try:
            call("user.logout", [])
        except Exception:
            pass
PY
