#!/usr/bin/env bash
set -euo pipefail
NS="${NAMESPACE:-zabbix}"

PHP_BIN="$(kubectl -n "$NS" exec deployment/zabbix-web -c zabbix-web -- sh -c '
  for candidate in php php85 php84 php83 php82 php81; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      exit 0
    fi
  done
  # The frontend can run PHP-FPM without installing a PHP CLI binary.
  exit 0
')"

if [[ -n "$PHP_BIN" ]]; then
echo "== ClickHouse consultado pelo frontend ($PHP_BIN) =="
kubectl -n "$NS" exec -i deployment/zabbix-web -c zabbix-web -- "$PHP_BIN" <<'PHP'
<?php
$url = 'http://zabbix-proxy-clickhouse:8123/?database=telemetry';
$sql = "SELECT 'traces' AS signal, ServiceName, count() AS rows, toString(max(Timestamp)) AS last_event FROM otel_traces GROUP BY ServiceName UNION ALL SELECT 'logs', ServiceName, count(), toString(max(Timestamp)) FROM otel_logs GROUP BY ServiceName FORMAT JSONEachRow";
$ch = curl_init($url);
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $sql,
    CURLOPT_USERPWD => 'zabbix:zabbix-telemetry-change-me',
    CURLOPT_CONNECTTIMEOUT => 5,
    CURLOPT_TIMEOUT => 15
]);
$body = curl_exec($ch);
$status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
echo "HTTP=$status frontend_UTC=".gmdate('c')."\n";
if ($body === false) {
    fwrite(STDERR, curl_error($ch)."\n");
    exit(1);
}
echo $body."\n";
if ($status !== 200) exit(1);

// An explicit frontend override takes precedence over the global UI setting.
foreach (['/etc/zabbix/web/zabbix.conf.php', '/usr/share/zabbix/conf/zabbix.conf.php'] as $path) {
    if (!is_readable($path)) continue;
    $source = file_get_contents($path);
    $active = preg_replace('~/\*.*?\*/|//[^\n]*|#[^\n]*~s', '', $source);
    echo "frontend_config=$path telemetry_override_reference=";
    echo strpos($active, '$TELEMETRY_PROVIDERS') !== false ? "yes\n" : "no\n";
    break;
}
PHP
else
echo '== PHP CLI ausente; testando HTTP do ClickHouse a partir do pod web =='
kubectl -n "$NS" exec -i deployment/zabbix-web -c zabbix-web -- sh -c '
  date -u
  if ! command -v wget >/dev/null 2>&1; then
    echo "O pod web não possui PHP CLI nem wget para este diagnóstico." >&2
    exit 1
  fi
  wget -O- -T 15 \
    --header "X-ClickHouse-User: zabbix" \
    --header "X-ClickHouse-Key: zabbix-telemetry-change-me" \
    --post-file=/dev/stdin \
    "http://zabbix-proxy-clickhouse:8123/?database=telemetry"
' <<'SQL'
SELECT 'traces' AS signal, ServiceName, count() AS rows, toString(max(Timestamp)) AS last_event FROM otel_traces GROUP BY ServiceName UNION ALL SELECT 'logs', ServiceName, count(), toString(max(Timestamp)) FROM otel_logs GROUP BY ServiceName FORMAT JSONEachRow
SQL
fi

echo '== configuração APM global salva (valores sensíveis ocultados) =='
kubectl -n "$NS" exec zabbix-postgres-0 -- sh -c '
  psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "SELECT row_to_json(s) FROM settings s WHERE name ILIKE '\''%apm%'\'' OR name ILIKE '\''%telemetry%'\''"
' | python3 -c '
import json,re,sys
def redact(value):
    if isinstance(value,dict):
        return {k:("<redacted>" if re.search("password|passwd|secret|token",k,re.I) else redact(v)) for k,v in value.items()}
    if isinstance(value,list): return [redact(v) for v in value]
    if isinstance(value,str):
        try: return redact(json.loads(value)) if value.startswith(("{","[")) else value
        except ValueError: return "<unparsed value>"
    return value
for line in sys.stdin:
    row=json.loads(line)
    if re.search("password|passwd|secret|token",row.get("name",""),re.I):
        row={"name":row["name"],"value":"<redacted>"}
    print(json.dumps(redact(row),ensure_ascii=False))
'
