import os
import logging
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, SimpleSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource


class LoggingSpanExporter:
    def __init__(self, exporter):
        self.exporter = exporter
        self.logger = logging.getLogger("telemetry-exporter")

    def export(self, spans):
        try:
            result = self.exporter.export(spans)
            self.logger.warning("OTLP export spans=%d result=%s", len(spans), result)
            return result
        except Exception:
            self.logger.exception("OTLP export raised an exception")
            raise

    def shutdown(self):
        return self.exporter.shutdown()

    def force_flush(self, timeout_millis=30000):
        return self.exporter.force_flush(timeout_millis)

def setup_tracing():
    resource = Resource.create({
        "service.name": os.getenv("OTEL_SERVICE_NAME", "chaos-backend"),
        "service.version": os.getenv("OTEL_SERVICE_VERSION", "1.0.0"),
        "deployment.environment": os.getenv("OTEL_DEPLOYMENT_ENVIRONMENT", "kind"),
    })
    provider = TracerProvider(resource=resource)

    if os.getenv("OTEL_DEBUG", "false").lower() == "true":
        logging.getLogger("opentelemetry").setLevel(logging.DEBUG)

    # Use the traces-specific endpoint when present. This avoids ambiguity
    # between OTLP protocols in a lab that exposes only OTLP/gRPC on 4317.
    otlp_endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"),
    ).rstrip("/")
    exporter = LoggingSpanExporter(
        OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True, timeout=5)
    )

    if os.getenv("OTEL_SIMPLE_EXPORT", "false").lower() == "true":
        processor = SimpleSpanProcessor(exporter)
    else:
        processor = BatchSpanProcessor(
            exporter,
            schedule_delay_millis=int(os.getenv("OTEL_BSP_SCHEDULE_DELAY_MILLIS", "500")),
        )
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)


def flush_traces() -> bool:
    provider = trace.get_tracer_provider()
    force_flush = getattr(provider, "force_flush", None)
    return bool(force_flush(5000)) if force_flush else False
