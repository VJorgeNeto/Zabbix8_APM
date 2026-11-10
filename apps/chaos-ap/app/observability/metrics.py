from prometheus_client import Counter, Histogram

# Métricas Customizadas
HTTP_REQUESTS_TOTAL = Counter(
    'http_requests_total', 'Total de requisições HTTP', ['method', 'endpoint', 'http_status']
)

HTTP_REQUEST_DURATION = Histogram(
    'http_request_duration_seconds', 'Duração das requisições HTTP', ['method', 'endpoint']
)

DB_QUERY_DURATION = Histogram(
    'db_query_duration_seconds', 'Tempo de execução de queries', ['operation']
)

CACHE_HITS = Counter('cache_hits_total', 'Total de hits no Redis')
CACHE_MISSES = Counter('cache_misses_total', 'Total de misses no Redis')
ERRORS_TOTAL = Counter('errors_total', 'Total de erros na aplicação', ['type'])