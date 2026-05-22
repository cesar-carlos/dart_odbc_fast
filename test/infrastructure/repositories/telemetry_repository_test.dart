import 'package:odbc_fast/domain/errors/telemetry_error.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:odbc_fast/infrastructure/native/bindings/opentelemetry_ffi.dart';
import 'package:odbc_fast/infrastructure/native/telemetry/console.dart';
import 'package:odbc_fast/infrastructure/repositories/telemetry_repository.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

void main() {
  group('TelemetryRepositoryImpl', () {
    test('initialize returns success when native client initializes', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      final result = await repository.initialize(
        otlpEndpoint: 'http://collector:4318',
      );

      expect(result.isSuccess(), isTrue);
      expect(fake.initializeCalls, equals(['http://collector:4318']));
    });

    test('initialize returns initialization failure on native failure',
        () async {
      final fake = _FakeTelemetryNativeClient(initializeResult: 0);
      final repository = TelemetryRepositoryImpl(fake);

      final result = await repository.initialize();

      expect(result.isError(), isTrue);
      final error = result.exceptionOrNull();
      expect(error, isA<TelemetryInitializationException>());
      expect(error?.message, contains('Failed to initialize telemetry'));
    });

    test('exportTrace before init does not throw and leaves native empty',
        () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.exportTrace(_trace());

      expect(fake.exportedTraces, isEmpty);
    });

    test('exportSpan after init with fallback recorder succeeds', () async {
      final fake = _FakeTelemetryNativeClient();
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(fake, batchSize: 1)
        ..setFallbackExporter(exporter);

      await repository.initialize();
      final result = await repository.exportSpan(_span());

      expect(result.isSuccess(), isTrue);
    });

    test('flush before init returns NOT_INITIALIZED', () async {
      final repository = TelemetryRepositoryImpl(_FakeTelemetryNativeClient());

      final result = await repository.flush();

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
    });

    test('shutdown returns TelemetryShutdownException when native throws',
        () async {
      final fake = _FakeTelemetryNativeClient()
        ..throwOnShutdown = Exception('native shutdown failed');
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.shutdown();

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<TelemetryShutdownException>());
    });

    test('export operations fail when repository is not initialized', () async {
      final repository = TelemetryRepositoryImpl(_FakeTelemetryNativeClient());

      final span = await repository.exportSpan(_span());
      final metric = await repository.exportMetric(_metric());
      final event = await repository.exportEvent(_event());
      final flush = await repository.flush();

      expect(span.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
      expect(metric.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
      expect(event.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
      expect(flush.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
    });

    test('setFallbackExporter activates fallback for buffered exports',
        () async {
      final fake = _FakeTelemetryNativeClient();
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(fake, batchSize: 1)
        ..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportTrace(_trace());
      await repository.exportSpan(_span());
      await repository.exportMetric(_metric());
      await repository.exportEvent(_event());

      expect(exporter.traces, hasLength(1));
      expect(exporter.spans, hasLength(1));
      expect(exporter.metrics, hasLength(1));
      expect(exporter.events, hasLength(1));
    });

    test('updateTrace serializes updated trace through native client',
        () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.updateTrace(
        traceId: 'trace-1',
        endTime: DateTime.utc(2026, 1, 2, 3, 4, 5),
        attributes: const {'db.system': 'odbc'},
      );

      expect(result.isSuccess(), isTrue);
      expect(fake.exportedTraces, hasLength(1));
      expect(fake.exportedTraces.single, contains('"trace_id":"trace-1"'));
      expect(fake.exportedTraces.single, contains('"db.system":"odbc"'));
    });

    test('updateSpan maps native exceptions to telemetry failures', () async {
      final fake = _FakeTelemetryNativeClient()
        ..throwOnExportTrace = Exception('native export failed');
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.updateSpan(
        spanId: 'span-1',
        endTime: DateTime.utc(2026),
      );

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('UPDATE_SPAN_FAILED'));
    });

    test('shutdown flushes buffered data and shuts native client down',
        () async {
      final fake = _FakeTelemetryNativeClient();
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(fake, batchSize: 10)
        ..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportSpan(_span());
      final result = await repository.shutdown();

      expect(result.isSuccess(), isTrue);
      expect(exporter.spans, hasLength(1));
      expect(fake.shutdownCalls, equals(1));
    });

    test('shutdown is success when repository was not initialized', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      final result = await repository.shutdown();

      expect(result.isSuccess(), isTrue);
      expect(fake.shutdownCalls, isZero);
    });

    test('updateTrace returns NOT_INITIALIZED before initialize', () async {
      final repository = TelemetryRepositoryImpl(_FakeTelemetryNativeClient());

      final result = await repository.updateTrace(
        traceId: 'x',
        endTime: DateTime.utc(2026),
      );

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
    });

    test('updateSpan returns NOT_INITIALIZED before initialize', () async {
      final repository = TelemetryRepositoryImpl(_FakeTelemetryNativeClient());

      final result = await repository.updateSpan(
        spanId: 's',
        endTime: DateTime.utc(2026),
      );

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('NOT_INITIALIZED'));
    });

    test('updateTrace maps native exception to UPDATE_TRACE_FAILED', () async {
      final fake = _FakeTelemetryNativeClient()
        ..throwOnExportTrace = Exception('native');
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.updateTrace(
        traceId: 'trace-z',
        endTime: DateTime.utc(2026),
      );

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('UPDATE_TRACE_FAILED'));
    });

    test('initialize maps unexpected native throw to INIT_ERROR', () async {
      final fake = _FakeTelemetryNativeClient()
        ..throwOnInit = Exception('ffi down');
      final repository = TelemetryRepositoryImpl(fake);

      final result = await repository.initialize();

      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull()?.code, equals('INIT_ERROR'));
    });

    test('flush succeeds after initialize and exports buffered span', () async {
      final fake = _FakeTelemetryNativeClient();
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(fake, batchSize: 10)
        ..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportSpan(_span());

      final result = await repository.flush();

      expect(result.isSuccess(), isTrue);
      expect(exporter.spans, hasLength(1));
    });

    test('exportMetric succeeds after initialize', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.exportMetric(_metric());

      expect(result.isSuccess(), isTrue);
    });

    test('exportEvent succeeds after initialize', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.exportEvent(_event());

      expect(result.isSuccess(), isTrue);
    });

    test('exportTrace after init flushes batch to fallback exporter', () async {
      final fake = _FakeTelemetryNativeClient();
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(fake, batchSize: 1)
        ..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportTrace(_trace());

      expect(exporter.traces, hasLength(1));
    });

    test('updateSpan succeeds and serializes through native client', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      final result = await repository.updateSpan(
        spanId: 'span-ok',
        endTime: DateTime.utc(2026, 2),
        attributes: const {'span.kind': 'internal'},
      );

      expect(result.isSuccess(), isTrue);
      expect(fake.exportedTraces, hasLength(1));
      expect(fake.exportedTraces.single, contains('"span_id":"span-ok"'));
      expect(fake.exportedTraces.single, contains('"span.kind":"internal"'));
    });

    test('batch export tolerates synchronous exporter failures', () async {
      final exporter = _SyncThrowingConsoleExporter();
      final repository = TelemetryRepositoryImpl(
        _FakeTelemetryNativeClient(),
        batchSize: 1,
      )..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportTrace(_trace());

      expect(exporter.exportAttempts, greaterThanOrEqualTo(1));
    });

    test('batch export records TelemetryException failures', () async {
      final exporter = _SyncTelemetryExceptionExporter();
      final repository = TelemetryRepositoryImpl(
        _FakeTelemetryNativeClient(),
        batchSize: 1,
      )..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportSpan(_span());

      expect(exporter.exportAttempts, equals(1));
    });

    test('reentrant flush during batch export is ignored', () async {
      final exporter = _ReentrantFlushExporter();
      final repository = TelemetryRepositoryImpl(
        _FakeTelemetryNativeClient(),
        batchSize: 1,
      )..setFallbackExporter(exporter);
      exporter.repository = repository;

      await repository.initialize();
      await repository.exportMetric(_metric());

      expect(exporter.nestedFlushCalls, greaterThanOrEqualTo(1));
    });

    test('exportMetric auto-flush exports through fallback recorder', () async {
      final exporter = _RecordingConsoleExporter();
      final repository = TelemetryRepositoryImpl(
        _FakeTelemetryNativeClient(),
        batchSize: 2,
      )..setFallbackExporter(exporter);

      await repository.initialize();
      await repository.exportMetric(_metric());
      await repository.exportMetric(
        Metric(
          name: 'query.latency',
          value: 12,
          unit: 'ms',
          timestamp: DateTime.utc(2026, 3),
        ),
      );

      expect(exporter.metrics, hasLength(2));
    });

    test('updateSpan serializes parent_span_id in native payload', () async {
      final fake = _FakeTelemetryNativeClient();
      final repository = TelemetryRepositoryImpl(fake);

      await repository.initialize();
      await repository.updateSpan(
        spanId: 'child-span',
        endTime: DateTime.utc(2026, 4),
        attributes: const {'parent': 'root'},
      );

      expect(fake.exportedTraces.single, contains('"parent_span_id":""'));
      expect(fake.exportedTraces.single, contains('"span_id":"child-span"'));
    });
  });
}

Trace _trace() => Trace(
      traceId: 'trace-1',
      name: 'query',
      startTime: DateTime.utc(2026),
      attributes: const {'component': 'test'},
    );

Span _span() => Span(
      spanId: 'span-1',
      traceId: 'trace-1',
      name: 'execute',
      startTime: DateTime.utc(2026),
    );

Metric _metric() => Metric(
      name: 'query.count',
      value: 1,
      unit: 'count',
      timestamp: DateTime.utc(2026),
    );

TelemetryEvent _event() => TelemetryEvent(
      name: 'query.failed',
      severity: TelemetrySeverity.error,
      message: 'failed',
      timestamp: DateTime.utc(2026),
    );

class _FakeTelemetryNativeClient implements TelemetryNativeClient {
  _FakeTelemetryNativeClient({this.initializeResult = 1});

  final int initializeResult;
  final List<String> initializeCalls = [];
  final List<String> exportedTraces = [];
  int shutdownCalls = 0;
  Exception? throwOnExportTrace;
  Exception? throwOnInit;
  Exception? throwOnShutdown;

  @override
  int initialize([String otlpEndpoint = '']) {
    final throwInit = throwOnInit;
    if (throwInit != null) {
      throw throwInit;
    }
    initializeCalls.add(otlpEndpoint);
    return initializeResult;
  }

  @override
  int exportTrace(String traceJson) {
    final exception = throwOnExportTrace;
    if (exception != null) {
      throw exception;
    }
    exportedTraces.add(traceJson);
    return 1;
  }

  @override
  int exportTraceToString(String input) => 1;

  @override
  int exportSpan(String spanJson) => exportTrace(spanJson);

  @override
  int exportMetric(String metricJson) => exportTrace(metricJson);

  @override
  int exportEvent(String eventJson) => exportTrace(eventJson);

  @override
  int updateTrace(String traceId, String endTime, String attributesJson) => 1;

  @override
  int updateSpan(String spanId, String endTime, String attributesJson) => 1;

  @override
  int flush() => 1;

  @override
  int shutdown() {
    shutdownCalls++;
    final throwShutdown = throwOnShutdown;
    if (throwShutdown != null) {
      throw throwShutdown;
    }
    return 1;
  }

  @override
  String getLastErrorMessage() => '';
}

class _SyncThrowingConsoleExporter extends ConsoleExporter {
  int exportAttempts = 0;

  @override
  Future<ResultDart<void, Exception>> exportTrace(Trace trace) {
    exportAttempts++;
    throw Exception('sync trace export failed');
  }

  @override
  Future<ResultDart<void, Exception>> exportSpan(Span span) {
    exportAttempts++;
    throw Exception('sync span export failed');
  }

  @override
  Future<ResultDart<void, Exception>> exportMetric(Metric metric) {
    exportAttempts++;
    throw Exception('sync metric export failed');
  }

  @override
  Future<ResultDart<void, Exception>> exportEvent(TelemetryEvent event) {
    exportAttempts++;
    throw Exception('sync event export failed');
  }
}

class _SyncTelemetryExceptionExporter extends ConsoleExporter {
  int exportAttempts = 0;

  @override
  Future<ResultDart<void, Exception>> exportSpan(Span span) {
    exportAttempts++;
    throw TelemetryException.now(message: 'span export failed', code: 'EXPORT');
  }
}

class _ReentrantFlushExporter extends ConsoleExporter {
  TelemetryRepositoryImpl? repository;
  int nestedFlushCalls = 0;

  @override
  Future<ResultDart<void, Exception>> exportMetric(Metric metric) {
    final repo = repository;
    if (repo != null) {
      nestedFlushCalls++;
      repo.flush();
    }
    return super.exportMetric(metric);
  }
}

class _RecordingConsoleExporter extends ConsoleExporter {
  final List<Trace> traces = [];
  final List<Span> spans = [];
  final List<Metric> metrics = [];
  final List<TelemetryEvent> events = [];

  @override
  Future<ResultDart<void, Exception>> exportTrace(Trace trace) async {
    traces.add(trace);
    return const Success(unit);
  }

  @override
  Future<ResultDart<void, Exception>> exportSpan(Span span) async {
    spans.add(span);
    return const Success(unit);
  }

  @override
  Future<ResultDart<void, Exception>> exportMetric(Metric metric) async {
    metrics.add(metric);
    return const Success(unit);
  }

  @override
  Future<ResultDart<void, Exception>> exportEvent(TelemetryEvent event) async {
    events.add(event);
    return const Success(unit);
  }
}
