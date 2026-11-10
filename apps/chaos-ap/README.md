# Chaos App

API Python/FastAPI para demonstrar tracing distribuído e falhas controladas.
Neste laboratório ela recebe o nome de serviço `chaos-backend` e chama a
API `dependency-api` propagando o contexto de trace.

## Instrumentação

- FastAPI e Requests instrumentados com OpenTelemetry.
- Traces exportados por OTLP/gRPC ao OpenTelemetry Collector.
- Logs em JSON no stdout e também por OTLP ao Grafana Alloy.
- Métricas Prometheus de requisições, erros e duração em `/metrics/`.

O pipeline Kubernetes completo é instalado pelo [Helmfile raiz](../../helmfile.yaml).
As instruções de demonstração estão no [README principal](../../README.md).

## Executar a API isolada

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
PYTHONPATH=app uvicorn main:app --app-dir app --host 127.0.0.1 --port 8000
```

Para exportar telemetria, configure `OTEL_EXPORTER_OTLP_ENDPOINT` e
`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` apontando para receivers disponíveis. Para
chamadas entre serviços, configure `DEPENDENCY_API_URL` com a URL da dependência.

## Rotas

| Rota | Cenário |
|---|---|
| `/health` | Disponibilidade |
| `/slow` | Atraso aleatório |
| `/error` | HTTP 500 controlado |
| `/random-failure` | 30% de probabilidade de HTTP 500 |
| `/external-api?scenario=healthy` | Dependência saudável |
| `/external-api?scenario=slow` | Dependência com latência |
| `/external-api?scenario=error` | Dependência indisponível, resposta 502 |
| `POST /load-test/cpu-spike` | CPU por três segundos |
| `POST /load-test/memory-leak` | Alocação de aproximadamente 10 MB |
| `/debug/telemetry` | Span de verificação e flush |

Os cenários de CPU e memória devem ser usados somente em ambiente de teste.
