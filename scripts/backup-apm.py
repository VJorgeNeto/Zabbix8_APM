"""Logical backup of APM tables before the ClickHouse upgrade.

Preserves CREATE statements and Native data streams. Each table is copied
independently while the append-only telemetry pipeline continues running.
"""
import gzip
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

namespace = os.environ.get("NAMESPACE", "zabbix")
target = Path(tempfile.mkdtemp(prefix="zabbix-apm-backup-", dir=str(Path.home())))

def command(query):
    return ["kubectl", "-n", namespace, "exec", "zabbix-proxy-clickhouse-0", "--",
            "sh", "-c", 'exec clickhouse-client --user "$CLICKHOUSE_USER" '
            '--password "$CLICKHOUSE_PASSWORD" --database "$CLICKHOUSE_DB" --query "$1"',
            "sh", query]

try:
    print("Backup local:", target, flush=True)
    version = subprocess.check_output(command("SELECT version()"), text=True).strip()
    (target / "version.txt").write_text(version + "\n")
    rows = subprocess.check_output(command(
        "SELECT name, engine FROM system.tables WHERE database=currentDatabase() "
        "AND startsWith(name, 'otel_') ORDER BY name FORMAT JSONEachRow"), text=True)
    tables = [json.loads(line) for line in rows.splitlines()]
    if not tables:
        raise RuntimeError("Nenhuma tabela APM encontrada; atualização cancelada")
    for table in tables:
        name = table["name"]
        if not re.fullmatch(r"[a-zA-Z0-9_]+", name):
            raise RuntimeError("Nome de tabela inesperado")
        schema = subprocess.check_output(command("SHOW CREATE TABLE `" + name + "` FORMAT TSVRaw"))
        (target / (name + ".sql")).write_bytes(schema)
        if "MergeTree" in table["engine"]:
            with gzip.open(target / (name + ".native.gz"), "wb") as output:
                with subprocess.Popen(command("SELECT * FROM `" + name + "` FORMAT Native"),
                                      stdout=subprocess.PIPE) as proc:
                    while True:
                        chunk = proc.stdout.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                    if proc.wait() != 0:
                        raise RuntimeError("Falha ao copiar " + name)
        print("Backup OK:", name, flush=True)
    (target / "tables.json").write_text(json.dumps(tables, indent=2))
    (target / "BACKUP_COMPLETE").touch()
    print("Backup concluído:", target, flush=True)
except Exception:
    print("Backup incompleto; arquivos preservados em", target, flush=True)
    raise
