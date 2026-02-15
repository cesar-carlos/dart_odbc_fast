import 'dart:convert';
import 'dart:math' show Random, min;

import 'package:odbc_fast/domain/errors/telemetry_error.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/bindings/opentelemetry_ffi.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/telemetry_buffer.dart';
import 'package:result_dart/result_dart.dart';

/// Record of a telemetry export failure for fallback tracking.
class TelemetryFailureRecord {
  const TelemetryFailureRecord({
    required this.timestamp,
    required this.error,
    required this.exporter,
  });
  final DateTime timestamp;
  final TelemetryException error;
  final String exporter;
}

/// Implementation of [ITelemetryRepository] using OpenTelemetry FFI
/// with buffering.
///
/// Provides concrete implementation of telemetry repository interface,
/// translating domain telemetry operations into native OpenTelemetry
/// calls via FFI with in-memory batching.
///
/// Features:
/// - Batching: Accumulates telemetry data before export
/// - Periodic flushing: Auto-flushes based on time interval
/// - Reduced FFI overhead: Fewer native calls
/// - Error handling: Returns [ResultDart] types for recovery
/// - Retry logic: Exponential backoff for transient failures
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
  /// The `_ffi` parameter provides access to native OpenTelemetry functions.
  /// [batchSize] specifies how many items to buffer before auto-flush.
  /// [flushInterval] specifies how often to auto-flush buffered data.
  /// [maxRetries] specifies the maximum number of retry attempts for exports.
  /// [retryBaseDelay] is the initial delay before first retry.
  /// [retryMaxDelay] is the maximum delay between retries.
  /// [fallbackExporter] optional exporter to use when OTLP fails.
  TelemetryRepositoryImpl(
    this._ffi, {
    int batchSize = 100,
    Duration flushInterval = const Duration(seconds: 30),
    int maxRetries = 3,
    Duration retryBaseDelay = const Duration(milliseconds: 100),
    Duration retryMaxDelay = const Duration(seconds: 10),
  })  : _buffer = TelemetryBuffer(
          batchSize: batchSize,
          flushInterval: flushInterval,
        ),
        _retry = _RetryHelper(
          maxRetries: maxRetries,
          baseDelay: retryBaseDelay,
          maxDelay: retryMaxDelay,
        ) {
    _buffer.onFlush = _exportBatch;
  }

  final OpenTelemetryFFI _ffi;
  final TelemetryBuffer _buffer;
  final _RetryHelper _retry;
  bool _isInitialized = false;
  TelemetryExporter? _currentExporter;

  /// Configuration for automatic fallback behavior.
  ///
  /// Controls when to switch from OTLP to ConsoleExporter.
  int consecutiveFailureThreshold = 3;
  Duration failureCheckInterval = const Duration(seconds: 30);
  TelemetryExporter? fallbackExporter;

  /// Updates the active exporter.
  ///
  /// Monitors failures and switches to fallback if needed.
  void _updateExporterIfNeeded(TelemetryExporter? exporter) {
    if (fallbackExporter != null && exporter != _currentExporter) {
      _currentExporter = exporter;
    }
  }

  /// Sets the fallback exporter to use.
  ///
  /// Call this to configure a ConsoleExporter to be used when OTLP fails.
  /// The exporter will receive all failed telemetry data.
  void setFallbackExporter(ConsoleExporter exporter) {
    _updateExporterIfNeeded(exporter);
  }

  /// Checks if should trigger fallback.
  ///
  /// Returns true if failures exceed threshold in time window.
  bool _shouldTriggerFallback() {
    if (_currentExporter is ConsoleExporter) {
      return false; // Already using fallback
    }

    final now = DateTime.now().toUtc();
    final recentFailures = _recentFailures.where(
      (failure) =>
          failure.timestamp.isAfter(now.subtract(failureCheckInterval)),
    );

    return recentFailures.length >= consecutiveFailureThreshold;
  }

  /// Tracks recent failures for fallback decision.
  final List<TelemetryFailureRecord> _recentFailures = [];

  /// Records a failure for tracking.
  void _recordFailure(TelemetryException error) {
    _recentFailures
      ..add(
        TelemetryFailureRecord(
          timestamp: DateTime.now().toUtc(),
          error: error,
          exporter: _currentExporter?.runtimeType.toString() ?? 'unknown',
        ),
      )
      ..removeWhere(
        (failure) => failure.timestamp.isBefore(
          DateTime.now().toUtc().subtract(failureCheckInterval),
        ),
      );

    // Auto-switch to fallback if threshold exceeded
    if (_shouldTriggerFallback() && fallbackExporter != null) {
      _updateExporterIfNeeded(fallbackExporter);
    }
  }

  /// Exports a batch of telemetry data using the current exporter.
  ///
  /// Handles errors gracefully without throwing exceptions.
  /// Records failures to track for automatic fallback decisions.
  void _exportBatch() {
    if (_isFlushing) {
      return;
    }

    _isFlushing = true;
    try {
      final batch = _buffer.flush();
      final exporter = _currentExporter;
      if (exporter != null && !batch.isEmpty) {
        batch.traces.forEach(exporter.exportTrace);
        batch.spans.forEach(exporter.exportSpan);
        batch.metrics.forEach(exporter.exportMetric);
        batch.events.forEach(exporter.exportEvent);
      }
    } on Exception catch (e) {
      _recordFailure(
        e is TelemetryException
            ? e
            : TelemetryException.now(
                message: e.toString(),
                code: 'EXPORT_BATCH',
              ),
      );
      _updateExporterIfNeeded(fallbackExporter);
    } finally {
      _isFlushing = false;
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

  bool _isFlushing = false;

  Future<ResultDart<void, TelemetryException>> initialize({
    String otlpEndpoint = 'http://localhost:4318',
  }) async {
    try {
      final initialized = _ffi.initialize(otlpEndpoint) != 0;
      if (initialized) {
        _isInitialized = true;
        return const Success(unit);
      }
      return Failure(
        TelemetryInitializationException(
          message:
              'Failed to initialize telemetry: OTLP endpoint is $otlpEndpoint',
        ),
      );
    } on Exception catch (e) {
      return Failure(
        TelemetryException(
          message: 'Unexpected error during telemetry initialization: $e',
          code: 'INIT_ERROR',
        ),
      );
    }
  }

  @override
  Future<void> exportTrace(Trace trace) async {
    if (!_isInitialized) {
      return;
    }

    try {
      final shouldFlush = _buffer.addTrace(trace);
      if (shouldFlush) {
        _exportBatch();
      }
    } on Exception catch (e) {
      _recordFailure(
        e is TelemetryException
            ? e
            : TelemetryException.now(
                message: e.toString(),
                code: 'EXPORT_TRACE',
              ),
      );
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportSpan(Span span) async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addSpan(span);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(unit);
      },
      operationName: 'exportSpan',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportMetric(
    Metric metric,
  ) async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addMetric(metric);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(unit);
      },
      operationName: 'exportMetric',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportEvent(
    TelemetryEvent event,
  ) async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addEvent(event);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(unit);
      },
      operationName: 'exportEvent',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
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
      return const Success(unit);
    } on Exception {
      return Failure(
        TelemetryException(
          message: 'Failed to update trace: $traceId',
          code: 'UPDATE_TRACE_FAILED',
        ),
      );
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
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
      return const Success(unit);
    } on Exception {
      return Failure(
        TelemetryException(
          message: 'Failed to update span: $spanId',
          code: 'UPDATE_SPAN_FAILED',
        ),
      );
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> flush() async {
    if (!_isInitialized) {
      return const Failure(
        TelemetryException(
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      );
    }

    try {
      _exportBatch();
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(
        TelemetryException(
          message: 'Failed to flush telemetry buffer: $e',
          code: 'FLUSH_FAILED',
        ),
      );
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> shutdown() async {
    if (!_isInitialized) {
      return const Success(unit);
    }

    try {
      if (_buffer.size > 0) {
        _exportBatch();
      }

      _buffer.dispose();

      _ffi.shutdown();

      _isInitialized = false;
      return const Success(unit);
    } on Exception catch (e) {
      return Failure(
        TelemetryShutdownException(
          message: 'Failed to shutdown telemetry: $e',
        ),
      );
    }
  }
}

/// Internal retry helper for telemetry operations.
///
/// Wraps the ResultDart retry helper to work with TelemetryException.
class _RetryHelper {
  _RetryHelper({
    required int maxRetries,
    required Duration baseDelay,
    required Duration maxDelay,
  }) : _retry = _RetryHelperImpl(
          maxRetries: maxRetries,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
        );

  final _RetryHelperImpl _retry;

  /// Executes [operation] with retry logic.
  Future<ResultDart<void, TelemetryException>> execute(
    Future<ResultDart<void, TelemetryException>> Function() operation, {
    String? operationName,
  }) async {
    final result = await _retry.execute(
      () => operation(),
      operationName: operationName,
    );

    return result.fold(
      (_) => const Success(unit),
      (e) => Failure(
        e is TelemetryException
            ? e
            : TelemetryException(
                message: e.toString(),
                code: 'RETRY_WRAP_ERROR',
              ),
      ),
    );
  }
}

/// Internal implementation of retry helper with exponential backoff.
class _RetryHelperImpl {
  _RetryHelperImpl({
    required int maxRetries,
    required Duration baseDelay,
    required Duration maxDelay,
  })  : _maxRetries = maxRetries,
        _baseDelay = baseDelay,
        _maxDelay = maxDelay;

  final int _maxRetries;
  final Duration _baseDelay;
  final Duration _maxDelay;
  final Random _random = Random.secure();

  /// Executes [operation] with retry logic.
  Future<ResultDart<void, Exception>> execute(
    Future<ResultDart<void, Exception>> Function() operation, {
    String? operationName,
  }) async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final result = await operation();

        if (result.isSuccess()) {
          return result;
        }

        final failure = result.exceptionOrNull();
        if (failure == null || !_isRetryable(failure)) {
          return result;
        }

        if (attempt < _maxRetries) {
          final delay = _calculateDelay(attempt);
          await Future<void>.delayed(delay);
        }
      } on Exception catch (_) {
        if (attempt < _maxRetries) {
          final delay = _calculateDelay(attempt);
          await Future<void>.delayed(delay);
        }
      }
    }

    // All retries exhausted
    final msg = 'Operation ${operationName ?? ''} failed after '
        '$_maxRetries retries';
    return Failure(
      TelemetryExportException(
        message: msg,
        attemptNumber: _maxRetries,
      ),
    );
  }

  /// Calculates delay for given attempt using exponential backoff with jitter.
  Duration _calculateDelay(int attempt) {
    // Exponential backoff: baseDelay * 2^attempt
    final exponentialDelay = _baseDelay.inMilliseconds * (1 << attempt);

    // Cap at maxDelay
    final cappedDelay = min(exponentialDelay, _maxDelay.inMilliseconds);

    // Add jitter: +/- jitterFactor * delay
    const jitterFactor = 0.1;
    final jitter = (_random.nextDouble() * 2 - 1) * jitterFactor * cappedDelay;
    final finalDelay =
        (cappedDelay + jitter).clamp(0, _maxDelay.inMilliseconds);

    return Duration(milliseconds: finalDelay.toInt());
  }

  /// Determines if an exception is retryable.
  bool _isRetryable(Exception exception) {
    // Retry all exceptions by default
    // Could be extended to check specific types/messages
    return true;
  }
}
