import 'dart:io' as io;
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:result_dart/result_dart.dart';

/// Interface for telemetry exporters.
///
/// Implementations can send telemetry data to various backends
/// such as OpenTelemetry OTLP, console stdout, files, etc.
abstract class TelemetryExporter {
  Future<ResultDart<void, Exception>> exportTrace(Trace trace);
  Future<ResultDart<void, Exception>> exportSpan(Span span);
  Future<ResultDart<void, Exception>> exportMetric(Metric metric);
  Future<ResultDart<void, Exception>> exportEvent(TelemetryEvent event);
}

/// Exporter that writes telemetry to console for debugging/fallback.
///
/// Used when OTLP exporter is unavailable or fails.
/// Provides simple stdout/stderr output for all telemetry data.
class ConsoleExporter implements TelemetryExporter {
  ConsoleExporter({io.IOSink? output}) : _output = output ?? io.stdout;
  final io.IOSink _output;

  @override
  Future<ResultDart<void, Exception>> exportTrace(Trace trace) async {
    try {
      final traceJson = _serializeTrace(trace);
      _output.writeln('[TRACE] $traceJson');
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(e);
    }
  }

  @override
  Future<ResultDart<void, Exception>> exportSpan(Span span) async {
    try {
      final spanJson = _serializeSpan(span);
      _output.writeln('[SPAN]  $spanJson');
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(e);
    }
  }

  @override
  Future<ResultDart<void, Exception>> exportMetric(Metric metric) async {
    try {
      final metricJson = _serializeMetric(metric);
      _output.writeln('[METRIC] $metricJson');
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(e);
    }
  }

  @override
  Future<ResultDart<void, Exception>> exportEvent(TelemetryEvent event) async {
    try {
      final eventJson = _serializeEvent(event);
      _output.writeln('[EVENT] $eventJson');
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(e);
    }
  }
}

String _serializeTrace(Trace trace) {
  final map = {
    'trace_id': trace.traceId,
    'name': trace.name,
    'start_time': trace.startTime.toIso8601String(),
    'end_time': trace.endTime?.toIso8601String(),
    'attributes': trace.attributes,
  };
  return _serializeTelemetryData(map);
}

String _serializeSpan(Span span) {
  final map = {
    'span_id': span.spanId,
    'parent_span_id': span.parentSpanId,
    'trace_id': span.traceId,
    'name': span.name,
    'start_time': span.startTime.toIso8601String(),
    'end_time': span.endTime?.toIso8601String(),
    'attributes': span.attributes,
  };
  return _serializeTelemetryData(map);
}

String _serializeMetric(Metric metric) {
  final map = {
    'name': metric.name,
    'value': metric.value,
    'unit': metric.unit,
    'timestamp': metric.timestamp.toIso8601String(),
    'attributes': metric.attributes,
  };
  return _serializeTelemetryData(map);
}

String _serializeEvent(TelemetryEvent event) {
  final map = {
    'name': event.name,
    'timestamp': event.timestamp.toIso8601String(),
    'severity': event.severity.name,
    'message': event.message,
    'attributes': event.context,
  };
  return _serializeTelemetryData(map);
}

String _serializeTelemetryData(Map<String, dynamic> map) {
  return '[${map.entries.map((e) => '${e.key}:${e.value}').join(',')}]';
}
