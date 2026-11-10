import logging
import os
from pythonjsonlogger import jsonlogger
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import SimpleLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter

class OTelJsonFormatter(jsonlogger.JsonFormatter):
    def add_fields(self, log_record, record, message_dict):
        super(OTelJsonFormatter, self).add_fields(log_record, record, message_dict)
        log_record['level'] = record.levelname

        # Injeta Trace ID e Span ID do OpenTelemetry no Log
        span = trace.get_current_span()
        if span.is_recording():
            span_context = span.get_span_context()
            log_record['trace_id'] = format(span_context.trace_id, '032x')
            log_record['span_id'] = format(span_context.span_id, '016x')
        else:
            log_record['trace_id'] = None
            log_record['span_id'] = None

def setup_logging():
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)

    # Remove handlers padrão
    while logger.hasHandlers():
        logger.removeHandler(logger.handlers[0])

    logHandler = logging.StreamHandler()
    formatter = OTelJsonFormatter('%(timestamp)s %(level)s %(name)s %(message)s')
    logHandler.setFormatter(formatter)
    logger.addHandler(logHandler)

    # Logs follow the explicit lab path: application -> Alloy -> Zabbix proxy.
    # Keep the stdout handler too, so kubectl logs remains useful while the
    # same records are indexed by the Zabbix APM datasource.
    logs_endpoint = os.getenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
    if logs_endpoint:
        logs_provider = LoggerProvider(
            resource=Resource.create({
                "service.name": os.getenv("OTEL_SERVICE_NAME", "chaos-backend"),
                "service.version": os.getenv("OTEL_SERVICE_VERSION", "1.0.0"),
                "deployment.environment": os.getenv("OTEL_DEPLOYMENT_ENVIRONMENT", "kind"),
            })
        )
        logs_provider.add_log_record_processor(
            SimpleLogRecordProcessor(
                OTLPLogExporter(endpoint=logs_endpoint, insecure=True, timeout=5)
            )
        )
        logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logs_provider))

    return logger
