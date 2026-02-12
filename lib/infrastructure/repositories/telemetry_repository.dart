import 'dart:convert';
import 'dart:math' show Random;

import 'package:odbc_fast/domain/errors/telemetry_error.dart' as err;
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/opentelemetry_ffi.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/telemetry_buffer.dart';
import 'package:result_dart/result_dart.dart';

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
  /// The [ffi] parameter provides access to native OpenTelemetry functions.
  /// [batchSize] specifies how many items to buffer before auto-flush.
  /// [flushInterval] specifies how often to auto-flush buffered data.
  /// [maxRetries] specifies the maximum number of retry attempts for exports.
  /// [retryBaseDelay] is the initial delay before first retry.
  /// [retryMaxDelay] is the maximum delay between retries.
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
    _buffer.setOnFlush(_exportBatch);
  }

  final OpenTelemetryFFI _ffi;
  final TelemetryBuffer _buffer;
  final _RetryHelper _retry;
  bool _isInitialized = false;
  bool _isShuttingDown = false;

  /// Exports a batch of telemetry data.
  ///
  /// Handles errors gracefully without throwing exceptions.
  void _exportBatch() {
    if (_isFlushing) {
      return;
    }

    _isFlushing = true;
    try {
      final batch = _buffer.flush();

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

  bool _isFlushing = false;

  @override
  Future<ResultDart<void, TelemetryException>> initialize({
    String otlpEndpoint = 'http://localhost:4318',
  }) async {
    try {
      final initialized = _ffi.initialize(otlpEndpoint: otlpEndpoint);
      if (initialized) {
        _isInitialized = true;
        return const Success(null);
      }
      return Failure(
        TelemetryInitializationException(
          message:
              'Failed to initialize telemetry: OTLP endpoint is $otlpEndpoint',
        ),
      );
    } on Exception catch (e) {
      return Failure(
        err.TelemetryException
          message: 'Unexpected error during telemetry initialization: $e',
          code: 'INIT_ERROR',
        ),
      )
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportTrace(Trace trace) async {
    if (!_isInitialized) {
      return const Failure(
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addTrace(trace);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(null);
      },
      operationName: 'exportTrace',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportSpan(Span span) async {
    if (!_isInitialized) {
      return const Failure(
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addSpan(span);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(null);
      },
      operationName: 'exportSpan',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportMetric(Metric metric) async {
    if (!_isInitialized) {
      return const Failure(
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addMetric(metric);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(null);
      },
      operationName: 'exportMetric',
    );
  }

  @override
  Future<ResultDart<void, TelemetryException>> exportEvent(
      TelemetryEvent event,) async {
    if (!_isInitialized) {
      return const Failure(
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
    }

    return _retry.execute(
      () async {
        final shouldFlush = _buffer.addEvent(event);
        if (shouldFlush) {
          _exportBatch();
        }
        return const Success(null);
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
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
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
      return const Success(null);
    } on Exception {
      return Failure(
        err.TelemetryException
          message: 'Failed to update trace: $traceId',
          code: 'UPDATE_TRACE_FAILED',
        ),
      )
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
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
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
      return const Success(null);
    } on Exception {
      return Failure(
        err.TelemetryException
          message: 'Failed to update span: $spanId',
          code: 'UPDATE_SPAN_FAILED',
        ),
      )
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> flush() async {
    if (!_isInitialized) {
      return const Failure(
        err.TelemetryException
          message: 'Telemetry not initialized',
          code: 'NOT_INITIALIZED',
        ),
      )
    }

    try {
      _exportBatch();
      return const Success(null);
    } on Exception catch (e) {
      return Failure(
        err.TelemetryException
          message: 'Failed to flush telemetry buffer: $e',
          code: 'FLUSH_FAILED',
        ),
      )
    }
  }

  @override
  Future<ResultDart<void, TelemetryException>> shutdown() async {
    if (!_isInitialized) {
      return const Success(null);
    }

    _isShuttingDown = true;

    try {
      if (_buffer.size > 0) {
        _exportBatch();
      }

      _buffer.dispose();

      _ffi.shutdown();

      _isInitialized = false;
      return const Success(null);
    } on Exception catch (e) {
      return Failure(
        TelemetryShutdownException(
          message: 'Failed to shutdown telemetry: $e',
        ),
      );
    }
  } finally {
    _isShuttingDown = false;
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
  })  : _retry = _RetryHelperImpl(
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

    // Convert generic Exception to TelemetryException if needed
    if (result.isError()) {
      final error = result.exceptionOrNull();
      if (error != null && error is! TelemetryException) {
        // Wrap non-TelemetryException errors
        return Failure(
          err.TelemetryException
            message: error.toString(),
            code: 'RETRY_WRAP_ERROR',
          ),
        )
      }
    }

    return result;
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
    Exception? lastException;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        final result = await operation();

        // If success, return immediately
        if (result.isSuccess()) {
          return result;
        }

        // Extract failure to check if retryable
        final failure = result.exceptionOrNull();
        if (failure == null || !_isRetryable(failure)) {
          return result; // Not retryable, return as-is
        }

        lastException = failure;

        // Don't delay after last attempt
        if (attempt < _maxRetries) {
          final delay = _calculateDelay(attempt);
          await Future.delayed(delay);
        }
      } on Exception catch (e) {
        // Unexpected exception - wrap and continue retry
        lastException = e;

        // Don't delay after last attempt
        if (attempt < _maxRetries) {
          final delay = _calculateDelay(attempt);
          await Future.delayed(delay);
        }
      }
    }

    // All retries exhausted
    return Failure(
      TelemetryExportException(
        message:
            'Operation ${operationName ?? ''} failed after $_maxRetries retries',
        attemptNumber: _maxRetries,
      ),
    );
  }

  /// Calculates delay for given attempt using exponential backoff with jitter.
  Duration _calculateDelay(int attempt) {
    // Exponential backoff: baseDelay * 2^attempt
    final exponentialDelay = _baseDelay.inMilliseconds * (1 << attempt);

    // Cap at maxDelay
    final cappedDelay =
        exponentialDelay.min(_maxDelay.inMilliseconds);

    // Add jitter: +/- jitterFactor * delay
    const jitterFactor = 0.1;
    final jitter =
        (_random.nextDouble() * 2 - 1) * jitterFactor * cappedDelay;
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
