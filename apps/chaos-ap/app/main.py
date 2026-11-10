import time
import random
import requests
import logging
import os
from fastapi import FastAPI, Request, Response, HTTPException
from prometheus_client import make_asgi_app
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry import trace

from observability.tracing import setup_tracing, flush_traces
from observability.logging import setup_logging
from observability.metrics import (
    HTTP_REQUESTS_TOTAL, HTTP_REQUEST_DURATION, ERRORS_TOTAL, CACHE_HITS, CACHE_MISSES
)

# Setup O11y
setup_tracing()
logger = setup_logging()
tracer = trace.get_tracer(__name__)

app = FastAPI(title="Chaos O11y Backend")

DEPENDENCY_API_URL = os.getenv("DEPENDENCY_API_URL", "https://jsonplaceholder.typicode.com/todos/1")

# Instrumentações automáticas
FastAPIInstrumentor.instrument_app(app)
RequestsInstrumentor().instrument()
# Psycopg2Instrumentor().instrument() # Descomente ao adicionar DB real
# RedisInstrumentor().instrument()    # Descomente ao adicionar Redis real

# Middleware para métricas RED (Rate, Errors, Duration)
@app.middleware("http")
async def prometheus_middleware(request: Request, call_next):
    start_time = time.time()
    method = request.method
    endpoint = request.url.path

    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as e:
        status_code = 500
        ERRORS_TOTAL.labels(type=type(e).__name__).inc()
        raise e
    finally:
        duration = time.time() - start_time
        HTTP_REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)
        HTTP_REQUESTS_TOTAL.labels(method=method, endpoint=endpoint, http_status=status_code).inc()

    return response

# Rota do Prometheus
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

# Variável para simular Memory Leak
memory_leak_list = []

# --- ENDPOINTS ---

@app.get("/health")
def health():
    logger.info("Verificação de healthcheck executada", extra={"endpoint": "/health"})
    return {"status": "up"}


@app.get("/debug/telemetry")
def debug_telemetry():
    """Create and synchronously flush one span for the lab verification script."""
    with tracer.start_as_current_span("zabbix_apm_probe") as span:
        span.set_attribute("demo.probe", True)
    return {"trace_export_flush": flush_traces()}

@app.get("/slow")
def slow_endpoint():
    delay = random.uniform(1.5, 4.0)
    logger.info(f"Iniciando processamento lento de {delay:.2f}s")

    with tracer.start_as_current_span("artificial_delay") as span:
        span.set_attribute("delay_seconds", delay)
        time.sleep(delay)

    logger.info("Processamento lento finalizado")
    return {"message": f"Demorou {delay:.2f} segundos"}

@app.get("/error")
def error_endpoint():
    logger.error("Erro proposital disparado pelo usuário!", extra={"endpoint": "/error"})
    ERRORS_TOTAL.labels(type="ValueError").inc()
    raise HTTPException(status_code=500, detail="Internal Server Error Simulado")

@app.get("/random-failure")
def random_failure():
    if random.random() < 0.3: # 30% de chance de erro
        logger.error("Falha aleatória ocorreu (30% de chance)")
        raise HTTPException(status_code=500, detail="Unlucky! Random failure triggered.")
    logger.info("Requisição passou pela roleta russa com sucesso")
    return {"status": "success"}

@app.get("/external-api")
def external_api(scenario: str = "healthy"):
    """Call a controllable dependency so the complete trace can be followed."""
    logger.info("Chamando dependência externa", extra={"scenario": scenario})
    try:
        # Request instrumentado automaticamente: the trace context is propagated.
        if DEPENDENCY_API_URL.startswith("http") and "jsonplaceholder" not in DEPENDENCY_API_URL:
            url = f"{DEPENDENCY_API_URL.rstrip('/')}/data"
            resp = requests.get(url, params={"scenario": scenario}, timeout=5)
        else:
            resp = requests.get(DEPENDENCY_API_URL, timeout=2)
        resp.raise_for_status()
        return resp.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Falha na API Externa: {str(e)}")
        ERRORS_TOTAL.labels(type="ExternalAPIError").inc()
        raise HTTPException(status_code=502, detail="Bad Gateway - External API Down")

@app.post("/load-test/memory-leak")
def simulate_memory_leak():
    logger.warning("Alocando memória não liberada (Memory Leak Simulado)")
    global memory_leak_list
    memory_leak_list.append(" " * 10**7) # Aloca ~10MB por chamada
    return {"message": "Memória alocada. Verifique o Grafana!"}

@app.post("/load-test/cpu-spike")
def simulate_cpu_spike():
    logger.warning("Iniciando spike de CPU por 3 segundos")
    with tracer.start_as_current_span("cpu_intensive_task"):
        end_time = time.time() + 3
        while time.time() < end_time:
            pass # Busy waiting loop
    return {"message": "CPU Spike finalizado."}
