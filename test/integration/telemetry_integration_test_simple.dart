import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';
import 'package:result_dart/result_dart.dart';

/// Mock implementation of ITelemetryRepository for testing without native FFI.
///
/// This mock tracks all telemetry calls and provides methods to reset counters.
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
    // No-op for mock - traces are just tracked by count
  }

  @override
  void updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) {
    // No-op for mock - spans are just tracked by count
  }

  @override
  void flush() {
    // No-op for mock
  }

  @override
  void shutdown() {
    _initialized = false;
  }

  // Reset counters for test isolation
  void resetCounters() {
    exportTraceCallCount = 0;
    exportSpanCallCount = 0;
    exportMetricCallCount = 0;
    exportEventCallCount = 0;
  }
}

void main() {
  group('Simple Telemetry Integration Tests (Mock)', () {
    late TelemetryService telemetryService;
    late MockTelemetryRepository mockRepository;

    setUp(() {
      mockRepository = MockTelemetryRepository();
      telemetryService = TelemetryService(mockRepository);
    });

    tearDown(() async {
      await telemetryService.shutdown();
    });

    test('should have correct service name', () {
      // Assert
      expect(telemetryService.serviceName, equals('odbc_fast'));
    });

    test('should start and end trace', () async {
      // Act
      final trace = await telemetryService.startTrace('test-operation');
      await telemetryService.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.exportTraceCallCount, equals(1));
      expect(trace.traceId, isNotEmpty);
      expect(trace.name, equals('test-operation'));
    });

    test('should create and end spans', () async {
      // Arrange
      final trace = await telemetryService.startTrace('test-operation');

      // Act
      final span1 = await telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'span1',
      );
      final span2 = await telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'span2',
      );
      await telemetryService.endSpan(spanId: span1.spanId);
      await telemetryService.endSpan(spanId: span2.spanId);
      await telemetryService.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.exportSpanCallCount, equals(2));
      expect(span1.parentSpanId, equals(trace.traceId));
      expect(span2.parentSpanId, equals(trace.traceId));
    });

    test('should record metric', () async {
      // Act
      await telemetryService.recordMetric(
        name: 'test-metric',
        metricType: 'counter',
        value: 42,
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(1));
    });

    test('should record gauge metric', () async {
      // Act
      await telemetryService.recordGauge(
        name: 'active-connections',
        value: 5,
        attributes: {'pool': 'main'},
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(2));
    });

    test('should record timing metric', () async {
      // Act
      await telemetryService.recordTiming(
        name: 'query-latency',
        duration: const Duration(milliseconds: 150),
        attributes: {'query': 'SELECT * FROM users'},
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(3));
    });

    test('should record event', () async {
      // Act
      await telemetryService.recordEvent(
        name: 'test-event',
        severity: TelemetrySeverity.info,
        message: 'Test event message',
        context: {'key': 'value'},
      );

      // Assert
      expect(mockRepository.exportEventCallCount, equals(1));
    });

    test('should handle multiple traces', () async {
      // Act
      final trace1 = await telemetryService.startTrace('operation-1');
      final trace2 = await telemetryService.startTrace('operation-2');
      await telemetryService.endTrace(traceId: trace1.traceId);
      await telemetryService.endTrace(traceId: trace2.traceId);

      // Assert
      expect(mockRepository.exportTraceCallCount, equals(2));
    });

    test('should record gauge metric', () async {
      // Act
      await telemetryService.recordGauge(
        name: 'active-connections',
        value: 5,
        attributes: {'pool': 'main'},
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(2));
    });

    test('should record timing metric', () async {
      // Act
      await telemetryService.recordTiming(
        name: 'query-latency',
        duration: const Duration(milliseconds: 150),
        attributes: {'query': 'SELECT * FROM users'},
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(3));
    });

    test('should record event', () async {
      // Act
      await telemetryService.recordEvent(
        name: 'test-event',
        severity: TelemetrySeverity.info,
        message: 'Test event message',
        context: {'key': 'value'},
      );

      // Assert
      expect(mockRepository.exportEventCallCount, equals(1));
    });

    test('should flush pending telemetry data', () async {
      // Arrange
      await telemetryService.recordMetric(
        name: 'metric1',
        metricType: 'counter',
        value: 1,
      );
      await telemetryService.recordMetric(
        name: 'metric2',
        metricType: 'counter',
        value: 2,
      );

      // Act
      await telemetryService.flush();

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(4));
    });

    test('should shutdown telemetry service', () async {
      // Act & Assert - should not throw
      await telemetryService.shutdown();
      expect(mockRepository.exportTraceCallCount, equals(0));
    });
  });
}
