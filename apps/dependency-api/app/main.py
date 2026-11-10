import logging
import os
import time

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter


def setup_tracing() -> None:
    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": os.getenv("OTEL_SERVICE_NAME", "dependency-api"),
                "service.version": os.getenv("OTEL_SERVICE_VERSION", "1.0.0"),
                "deployment.environment": os.getenv("OTEL_DEPLOYMENT_ENVIRONMENT", "kind"),
            }
        )
    )
    exporter = OTLPSpanExporter(
        endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
        insecure=True,
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


setup_tracing()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("dependency-api")

logs_endpoint = os.getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
if logs_endpoint:
    logs_provider = LoggerProvider(
        resource=Resource.create({
            "service.name": os.getenv("OTEL_SERVICE_NAME", "dependency-api"),
            "service.version": os.getenv("OTEL_SERVICE_VERSION", "1.0.0"),
            "deployment.environment": os.getenv("OTEL_DEPLOYMENT_ENVIRONMENT", "kind"),
        })
    )
    logs_provider.add_log_record_processor(
        SimpleLogRecordProcessor(OTLPLogExporter(endpoint=logs_endpoint, insecure=True, timeout=5))
    )
    logging.getLogger().addHandler(LoggingHandler(level=logging.INFO, logger_provider=logs_provider))

tracer = trace.get_tracer(__name__)

app = FastAPI(title="APM Dependency API")
FastAPIInstrumentor.instrument_app(app)


@app.get("/health")
def health():
    return {"status": "up"}


@app.get("/data")
def data(scenario: str = "healthy"):
    with tracer.start_as_current_span("dependency_processing") as span:
        span.set_attribute("demo.scenario", scenario)

        if scenario == "slow":
            delay = 2.5
            span.set_attribute("demo.delay_seconds", delay)
            logger.warning("Simulando dependência lenta: %.1fs", delay)
            time.sleep(delay)
        elif scenario == "error":
            span.set_attribute("demo.failure", True)
            logger.error("Simulando indisponibilidade da dependência")
            raise HTTPException(status_code=503, detail="Dependency unavailable (demo)")
        elif scenario != "healthy":
            raise HTTPException(status_code=400, detail="scenario must be healthy, slow or error")

        return {"status": "ok", "dependency": "dependency-api", "scenario": scenario}
