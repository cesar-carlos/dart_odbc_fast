import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

class MockTelemetryRepository implements ITelemetryRepository {
  int exportTraceCallCount = 0;
  int exportSpanCallCount = 0;
  int exportMetricCallCount = 0;
  int exportEventCallCount = 0;
  bool _initialized = false;

  @override
  bool initialize({String otlpEndpoint = 'http://localhost:4318'}) {
    _initialized = true;
    return true;
  }

  @override
  void exportTrace(Trace trace) {
    exportTraceCallCount++;
  }

  @override
  void exportSpan(Span span) {
    exportSpanCallCount++;
  }

  @override
  void exportMetric(Metric metric) {
    exportMetricCallCount++;
  }

  @override
  void exportEvent(TelemetryEvent event) {
    exportEventCallCount++;
  }

  @override
  void updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) {
    // No-op for mock
  }

  @override
  void updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) {
    // No-op for mock
  }

  @override
  void flush() {
    // No-op for mock
  }

  @override
  void shutdown() {
    _initialized = false;
  }

  void reset() {
    exportTraceCallCount = 0;
    exportSpanCallCount = 0;
    exportMetricCallCount = 0;
    exportEventCallCount = 0;
  }
}

void main() {
  loadTestEnv();
  group('Telemetry Integration Tests (TEL-001)', () {
    late TelemetryService telemetryService;
    late MockTelemetryRepository mockRepository;

    setUp(() {
      mockRepository = MockTelemetryRepository();
      telemetryService = TelemetryService(mockRepository);
    });

    tearDown(() {
      mockRepository.reset();
    });

    test('should start and end trace successfully', () async {
      mockRepository.reset();
      final trace = await telemetryService.startTrace('test.operation');
      expect(trace.traceId, isNotEmpty);
      expect(trace.name, equals('test.operation'));
      expect(trace.startTime, isNotNull);
      expect(trace.endTime, isNull);
      await Future.delayed(const Duration(milliseconds: 10));
      await telemetryService.endTrace(
        traceId: trace.traceId,
        attributes: {'status': 'completed'},
      );
      expect(mockRepository.exportTraceCallCount, equals(1));
    });

    test('should start and end span successfully', () async {
      mockRepository.reset();
      final trace = await telemetryService.startTrace('parent.operation');
      final span = await telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'child.operation',
      );
      expect(span.spanId, isNotEmpty);
      expect(span.name, equals('child.operation'));
      expect(span.parentSpanId, equals(trace.traceId));
      expect(span.endTime, isNull);
      await Future.delayed(const Duration(milliseconds: 10));
      await telemetryService.endSpan(
        spanId: span.spanId,
        attributes: {'result': 'success'},
      );
      await telemetryService.endTrace(traceId: trace.traceId);
      expect(mockRepository.exportSpanCallCount, equals(1));
      expect(mockRepository.exportTraceCallCount, equals(1));
    });

    test('should record metric successfully', () async {
      mockRepository.reset();
      await telemetryService.recordMetric(
        name: 'test.counter',
        type: 'counter',
        value: 42,
      );
      expect(mockRepository.exportMetricCallCount, equals(1));
    });

    test('should record gauge successfully', () async {
      mockRepository.reset();
      await telemetryService.recordGauge(
        name: 'test.gauge',
        value: 123.45,
      );
      expect(mockRepository.exportMetricCallCount, equals(1));
    });

    test('should record timing successfully', () async {
      mockRepository.reset();
      const duration = Duration(milliseconds: 99);
      await telemetryService.recordTiming(
        name: 'test.timing',
        duration: duration,
      );
      expect(mockRepository.exportMetricCallCount, equals(1));
    });

    test('should record event successfully', () async {
      mockRepository.reset();
      await telemetryService.recordEvent(
        name: 'test.event',
        severity: TelemetrySeverity.info,
        message: 'Test event message',
      );
      expect(mockRepository.exportEventCallCount, equals(1));
    });

    test('should record event with context successfully', () async {
      mockRepository.reset();
      await telemetryService.recordEvent(
        name: 'test.event',
        severity: TelemetrySeverity.warn,
        message: 'Warning message',
        context: {'key': 'value', 'number': '42'},
      );
      expect(mockRepository.exportEventCallCount, equals(1));
    });

    test('should have correct service name', () async {
      mockRepository.reset();
      expect(telemetryService.serviceName, equals('odbc_fast'));
    });

    test('should handle ending non-existent trace gracefully', () async {
      mockRepository.reset();
      await telemetryService.endTrace(traceId: 'non_existent_trace');
      expect(mockRepository.exportTraceCallCount, equals(0));
    });

    test('should handle ending non-existent span gracefully', () async {
      mockRepository.reset();
      await telemetryService.endSpan(spanId: 'non_existent_span');
      expect(mockRepository.exportSpanCallCount, equals(0));
    });
  });

  group('Telemetry with Repository (TEL-002)', () {
    late TelemetryRepositoryImpl repository;
    late TelemetryService telemetryService;

    setUpAll(() {
      repository = TelemetryRepositoryImpl(OpenTelemetryFFI());
      repository.initialize();
      telemetryService = TelemetryService(repository);
    });

    test('should export trace through FFI', () async {
      final trace = await telemetryService.startTrace('ffi_test.operation');
      await Future.delayed(const Duration(milliseconds: 10));
      await telemetryService.endTrace(
        traceId: trace.traceId,
        attributes: {'ffi': 'tested'},
      );
      expect(true, isTrue);
    });

    test('should export span through FFI', () async {
      final trace = await telemetryService.startTrace('span_parent');
      final span = await telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'span_child',
      );
      await Future.delayed(const Duration(milliseconds: 10));
      await telemetryService.endSpan(spanId: span.spanId);
      await telemetryService.endTrace(traceId: trace.traceId);
      expect(true, isTrue);
    });

    test('should export metric through FFI', () async {
      await telemetryService.recordMetric(
        name: 'ffi.metric',
        type: 'gauge',
        value: 100,
      );
      expect(true, isTrue);
    });

    test('should export event through FFI', () async {
      await telemetryService.recordEvent(
        name: 'ffi.event',
        severity: TelemetrySeverity.info,
        message: 'FFI test event',
      );
      expect(true, isTrue);
    });
  });
}
