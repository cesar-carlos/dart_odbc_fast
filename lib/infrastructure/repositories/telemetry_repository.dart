import 'dart:convert';

import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/opentelemetry_ffi.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/telemetry_buffer.dart';

/// Implementation of [ITelemetryRepository] using OpenTelemetry FFI with buffering.
///
/// Provides concrete implementation of telemetry repository interface,
/// translating domain telemetry operations into native OpenTelemetry calls
/// via FFI with in-memory batching.
///
/// Features:
/// - Batching: Accumulates telemetry data before export
/// - Periodic flushing: Auto-flushes based on time interval
/// - Reduced FFI overhead: Fewer native calls
///
/// Example:
/// ```dart
/// final ffi = OpenTelemetryFFI();
/// final repository = TelemetryRepositoryImpl(
///   ffi,
///   batchSize: 100,
///   flushInterval: Duration(seconds: 30),
/// );
/// repository.initialize();
/// ```
class TelemetryRepositoryImpl implements ITelemetryRepository {
  /// Creates a new [TelemetryRepositoryImpl] instance.
  ///
  /// The [ffi] parameter provides access to native OpenTelemetry functions.
  /// [batchSize] specifies how many items to buffer before auto-flush.
  /// [flushInterval] specifies how often to auto-flush buffered data.
  TelemetryRepositoryImpl(
    this._ffi, {
    int batchSize = 100,
    Duration flushInterval = const Duration(seconds: 30),
  }) : _buffer = TelemetryBuffer(
          batchSize: batchSize,
          flushInterval: flushInterval,
        ) {
    _buffer.setOnFlush(_exportBatch);
  }

  final OpenTelemetryFFI _ffi;
  final TelemetryBuffer _buffer;
  bool _isInitialized = false;

  @override
  bool initialize({String otlpEndpoint = 'http://localhost:4318'}) {
    try {
      final initialized = _ffi.initialize(otlpEndpoint: otlpEndpoint);
      if (initialized) {
        _isInitialized = true;
        return true;
      }
      return false;
    } on TelemetryException {
      return false;
    } on Exception {
      return false;
    }
  }

  @override
  void exportTrace(Trace trace) {
    if (!_isInitialized) {
      return;
    }

    final shouldFlush = _buffer.addTrace(trace);
    if (shouldFlush) {
      _flushSafely();
    }
  }

  @override
  void exportSpan(Span span) {
    if (!_isInitialized) {
      return;
    }

    final shouldFlush = _buffer.addSpan(span);
    if (shouldFlush) {
      _flushSafely();
    }
  }

  @override
  void exportMetric(Metric metric) {
    if (!_isInitialized) {
      return;
    }

    final shouldFlush = _buffer.addMetric(metric);
    if (shouldFlush) {
      _flushSafely();
    }
  }

  @override
  void exportEvent(TelemetryEvent event) {
    if (!_isInitialized) {
      return;
    }

    final shouldFlush = _buffer.addEvent(event);
    if (shouldFlush) {
      _flushSafely();
    }
  }

  @override
  void updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) {
    if (!_isInitialized) {
      return;
    }

    try {
      final updatedTrace = Trace(
        traceId: traceId,
        name: '',
        startTime: DateTime.now().subtract(const Duration(seconds: 1)),
        endTime: endTime,
        attributes: attributes,
      );
      final traceJson = _serializeTrace(updatedTrace);
      _ffi.exportTrace(traceJson);
    } on TelemetryException {
      // Silently ignore telemetry exceptions
    } on Exception {
      // Silently ignore exceptions
    }
  }

  @override
  void updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) {
    if (!_isInitialized) {
      return;
    }

    try {
      final updatedSpan = Span(
        spanId: spanId,
        parentSpanId: '',
        traceId: '',
        name: '',
        startTime: DateTime.now().subtract(const Duration(seconds: 1)),
        endTime: endTime,
        attributes: attributes,
      );
      final spanJson = _serializeSpan(updatedSpan);
      _ffi.exportTrace(spanJson);
    } on TelemetryException {
      // Silently ignore telemetry exceptions
    } on Exception {
      // Silently ignore exceptions
    }
  }

  @override
  void flush() {
    _flushSafely();
  }

  @override
  void shutdown() {
    if (!_isInitialized) {
      return;
    }

    try {
      // Flush any remaining buffered data
      if (_buffer.size > 0) {
        _exportBatch();
      }

      _buffer.dispose();
      _ffi.shutdown();
      _isInitialized = false;
    } on Exception {
      // Silently ignore exceptions during shutdown
    }
  }

  /// Exports a batch of telemetry data to native layer.
  void _exportBatch() {
    final batch = _buffer.flush();
    if (batch.isEmpty) {
      return;
    }

    for (final trace in batch.traces) {
      try {
        final traceJson = _serializeTrace(trace);
        _ffi.exportTrace(traceJson);
      } on Exception {
        // Continue exporting other items
      }
    }

    for (final span in batch.spans) {
      try {
        final spanJson = _serializeSpan(span);
        _ffi.exportTrace(spanJson);
      } on Exception {
        // Continue exporting other items
      }
    }

    for (final metric in batch.metrics) {
      try {
        final metricJson = _serializeMetric(metric);
        _ffi.exportTrace(metricJson);
      } on Exception {
        // Continue exporting other items
      }
    }

    for (final event in batch.events) {
      try {
        final eventJson = _serializeEvent(event);
        _ffi.exportTrace(eventJson);
      } on Exception {
        // Continue exporting other items
      }
    }
  }

  /// Flushes buffered data with error handling.
  void _flushSafely() {
    try {
      _exportBatch();
    } on Exception {
      // Silently ignore flush errors
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
    return jsonEncode(map);
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
    return jsonEncode(map);
  }

  String _serializeMetric(Metric metric) {
    final map = {
      'name': metric.name,
      'value': metric.value,
      'unit': metric.unit,
      'timestamp': metric.timestamp.toIso8601String(),
      'attributes': metric.attributes,
    };
    return jsonEncode(map);
  }

  String _serializeEvent(TelemetryEvent event) {
    final map = {
      'name': event.name,
      'timestamp': event.timestamp.toIso8601String(),
      'severity': event.severity.name,
      'attributes': event.context,
    };
    return jsonEncode(map);
  }
}
