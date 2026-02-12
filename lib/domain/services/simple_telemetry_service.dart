import 'dart:math' show Random;

import 'package:odbc_fast/domain/services/itelemetry_service.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Simplified telemetry service for ODBC operations.
///
/// Provides methods for starting/ending traces, spans, and recording metrics.
/// Uses a simple [ITelemetryRepository] that doesn't return Result types.
class SimpleTelemetryService implements ITelemetryService {
  SimpleTelemetryService(this._repository);

  final ITelemetryRepository _repository;
  final Map<String, Trace> _activeTraces = {};
  final Map<String, Span> _activeSpans = {};
  final Random _random = Random.secure();

  @override
  String get serviceName => 'odbc_fast';

  /// Generates a UUID v4 for unique trace IDs.
  ///
  /// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  String _generateTraceId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-$hex';
  }

  /// Generates a UUID v4 for unique span IDs.
  ///
  /// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  String _generateSpanId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-$hex';
  }

  @override
  Trace startTrace(String operationName) {
    if (operationName.isEmpty) {
      throw ArgumentError('Operation name cannot be empty');
    }

    final traceId = _generateTraceId();
    final now = DateTime.now().toUtc();

    final trace = Trace(
      traceId: traceId,
      name: operationName,
      startTime: now,
      attributes: {},
    );

    _activeTraces[traceId] = trace;
    return trace;
  }

  @override
  Future<void> endTrace({
    required String traceId,
    Map<String, String> attributes = const {},
  }) async {
    if (traceId.isEmpty) {
      throw ArgumentError('Trace ID cannot be empty');
    }

    final cached = _activeTraces[traceId];
    if (cached == null) {
      throw Exception('Trace $traceId not found');
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    await _repository.updateTrace(
      traceId: traceId,
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _activeTraces.remove(traceId);
  }

  @override
  Span startSpan({
    required String parentId,
    required String spanName,
    Map<String, String> initialAttributes = const {},
  }) {
    if (spanName.isEmpty) {
      throw ArgumentError('Span name cannot be empty');
    }
    if (parentId.isEmpty) {
      throw ArgumentError('Parent ID cannot be empty');
    }

    final spanId = _generateSpanId();
    final now = DateTime.now().toUtc();

    final span = Span(
      spanId: spanId,
      parentSpanId: parentId,
      traceId: parentId,
      name: spanName,
      startTime: now,
      attributes: initialAttributes,
    );

    _activeSpans[spanId] = span;
    return span;
  }

  @override
  Future<void> endSpan({
    required String spanId,
    Map<String, String> attributes = const {},
  }) async {
    if (spanId.isEmpty) {
      throw ArgumentError('Span ID cannot be empty');
    }

    final cached = _activeSpans[spanId];
    if (cached == null) {
      throw Exception('Span $spanId not found');
    }

    final now = DateTime.now().toUtc();
    final duration = now.difference(cached.startTime);

    await _repository.updateSpan(
      spanId: spanId,
      endTime: now,
      attributes: {...cached.attributes, ...attributes},
    );

    _activeSpans.remove(spanId);
  }

  @override
  Future<void> recordMetric({
    required String name,
    required String metricType,
    required double value,
    String unit = 'count',
    Map<String, String> attributes = const {},
  }) async {
    if (name.isEmpty) {
      throw ArgumentError('Metric name cannot be empty');
    }
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError('Metric value must be a valid number');
    }
    if (unit.isEmpty) {
      throw ArgumentError('Metric unit cannot be empty');
    }

    await _repository.exportMetric(
      Metric(
        name: name,
        value: value,
        unit: unit,
        timestamp: DateTime.now().toUtc(),
        attributes: attributes,
      ),
    );
  }

  @override
  Future<void> recordGauge({
    required String name,
    required double value,
    Map<String, String> attributes = const {},
  }) async {
    if (name.isEmpty) {
      throw ArgumentError('Gauge name cannot be empty');
    }
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError('Gauge value must be a valid number');
    }

    await _repository.exportMetric(
      Metric(
        name: name,
        value: value,
        unit: 'count',
        timestamp: DateTime.now().toUtc(),
        attributes: attributes,
      ),
    );
  }

  @override
  Future<void> recordTiming({
    required String name,
    required Duration duration,
    Map<String, String> attributes = const {},
  }) async {
    if (name.isEmpty) {
      throw ArgumentError('Timing name cannot be empty');
    }
    if (duration.isNegative) {
      throw ArgumentError('Duration cannot be negative');
    }

    await _repository.exportMetric(
      Metric(
        name: name,
        value: duration.inMilliseconds.toDouble(),
        unit: 'ms',
        timestamp: DateTime.now().toUtc(),
        attributes: attributes,
      ),
    );
  }

  @override
  Future<void> recordEvent({
    required String name,
    required TelemetrySeverity severity,
    required String message,
    Map<String, dynamic> context = const {},
  }) async {
    if (name.isEmpty) {
      throw ArgumentError('Event name cannot be empty');
    }
    if (message.isEmpty) {
      throw ArgumentError('Event message cannot be empty');
    }

    await _repository.exportEvent(
      TelemetryEvent(
        name: name,
        severity: severity,
        message: message,
        timestamp: DateTime.now().toUtc(),
        context: context,
      ),
    );
  }

  @override
  Future<void> flush() async {
    await _repository.flush();
  }

  @override
  Future<void> shutdown() async {
    await _repository.shutdown();
  }
}
