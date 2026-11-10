"""Run in the demo container; the shell verifier checks actual storage."""
import json
import logging
import os
import uuid

from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor

run_id = uuid.uuid4().hex
resource = Resource.create({"service.name": "apm-smoke", "demo.run_id": run_id})
endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
traces = TracerProvider(resource=resource)
traces.add_span_processor(SimpleSpanProcessor(
    OTLPSpanExporter(endpoint=endpoint, insecure=True, timeout=5)))
logs = LoggerProvider(resource=resource)
logs.add_log_record_processor(SimpleLogRecordProcessor(OTLPLogExporter(
    endpoint=os.environ.get("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://alloy:4317"),
    insecure=True, timeout=5)))
logger = logging.getLogger("apm-smoke")
logger.setLevel(logging.INFO)
logger.propagate = False
logger.addHandler(LoggingHandler(logger_provider=logs))
reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=endpoint, insecure=True, timeout=5),
    export_interval_millis=60000,
)
metrics = MeterProvider(resource=resource, metric_readers=[reader])
with traces.get_tracer("apm-smoke").start_as_current_span("apm_pipeline_probe") as span:
    trace_id = format(span.get_span_context().trace_id, "032x")
    logger.info("APM pipeline probe %s", run_id)
    metrics.get_meter("apm-smoke").create_counter("apm_probe_total").add(1)
metrics.force_flush(timeout_millis=5000)
logs.force_flush(timeout_millis=5000)
traces.force_flush(timeout_millis=5000)
metrics.shutdown()
logs.shutdown()
traces.shutdown()
print(json.dumps({"run_id": run_id, "trace_id": trace_id}))
