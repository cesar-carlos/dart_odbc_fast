import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

/// Mock implementation of ITelemetryRepository for testing without native FFI.
///
/// This mock tracks all telemetry calls and provides methods to reset counters.
class MockTelemetryRepository implements ITelemetryRepository {
  int exportTraceCallCount = 0;
  int exportSpanCallCount = 0;
  int exportMetricCallCount = 0;
  int exportEventCallCount = 0;
  int updateTraceCallCount = 0;
  int updateSpanCallCount = 0;

  @override
  Future<void> exportTrace(Trace trace) async {
    exportTraceCallCount++;
  }

  @override
  Future<void> exportSpan(Span span) async {
    exportSpanCallCount++;
  }

  @override
  Future<void> exportMetric(Metric metric) async {
    exportMetricCallCount++;
  }

  @override
  Future<void> exportEvent(TelemetryEvent event) async {
    exportEventCallCount++;
  }

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    updateTraceCallCount++;
  }

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    updateSpanCallCount++;
  }

  @override
  Future<void> flush() async {
    // No-op for mock
  }

  @override
  Future<void> shutdown() async {
    // No-op for mock
  }
}

void main() {
  group('Simple Telemetry Integration Tests (Mock)', () {
    late SimpleTelemetryService telemetryService;
    late MockTelemetryRepository mockRepository;

    setUp(() {
      mockRepository = MockTelemetryRepository();
      telemetryService = SimpleTelemetryService(mockRepository);
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
      final trace = telemetryService.startTrace('test-operation');
      await telemetryService.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.updateTraceCallCount, equals(1));
      expect(trace.traceId, isNotEmpty);
      expect(trace.name, equals('test-operation'));
    });

    test('should create and end spans', () async {
      // Arrange
      final trace = telemetryService.startTrace('test-operation');

      // Act
      final span1 = telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'span1',
      );
      final span2 = telemetryService.startSpan(
        parentId: trace.traceId,
        spanName: 'span2',
      );
      await telemetryService.endSpan(spanId: span1.spanId);
      await telemetryService.endSpan(spanId: span2.spanId);
      await telemetryService.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.updateSpanCallCount, equals(2));
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
      expect(mockRepository.exportMetricCallCount, equals(1));
    });

    test('should record timing metric', () async {
      // Act
      await telemetryService.recordTiming(
        name: 'query-latency',
        duration: const Duration(milliseconds: 150),
        attributes: {'query': 'SELECT * FROM users'},
      );

      // Assert
      expect(mockRepository.exportMetricCallCount, equals(1));
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
      final trace1 = telemetryService.startTrace('operation-1');
      final trace2 = telemetryService.startTrace('operation-2');
      await telemetryService.endTrace(traceId: trace1.traceId);
      await telemetryService.endTrace(traceId: trace2.traceId);

      // Assert
      expect(mockRepository.updateTraceCallCount, equals(2));
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
      expect(mockRepository.exportMetricCallCount, equals(2));
    });

    test('should shutdown telemetry service', () async {
      // Act & Assert - should not throw
      await telemetryService.shutdown();
      expect(mockRepository.updateTraceCallCount, equals(0));
    });

    test('should validate metric name is not empty', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordMetric(
          name: '',
          metricType: 'counter',
          value: 42,
        ),
        throwsArgumentError,
      );
    });

    test('should validate gauge name is not empty', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordGauge(
          name: '',
          value: 5,
        ),
        throwsArgumentError,
      );
    });

    test('should validate timing name is not empty', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordTiming(
          name: '',
          duration: const Duration(milliseconds: 150),
        ),
        throwsArgumentError,
      );
    });

    test('should validate event name is not empty', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordEvent(
          name: '',
          severity: TelemetrySeverity.info,
          message: 'Test message',
        ),
        throwsArgumentError,
      );
    });

    test('should validate event message is not empty', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordEvent(
          name: 'test-event',
          severity: TelemetrySeverity.info,
          message: '',
        ),
        throwsArgumentError,
      );
    });

    test('should validate operation name is not empty', () {
      // Act & Assert
      expect(
        () => telemetryService.startTrace(''),
        throwsArgumentError,
      );
    });

    test('should validate span name is not empty', () {
      // Arrange
      final trace = telemetryService.startTrace('test-operation');

      // Act & Assert
      expect(
        () => telemetryService.startSpan(
          parentId: trace.traceId,
          spanName: '',
        ),
        throwsArgumentError,
      );
    });

    test('should validate parent ID is not empty', () {
      // Act & Assert
      expect(
        () => telemetryService.startSpan(
          parentId: '',
          spanName: 'test-span',
        ),
        throwsArgumentError,
      );
    });

    test('should validate trace ID is not empty when ending', () async {
      // Act & Assert
      expect(
        () => telemetryService.endTrace(traceId: ''),
        throwsArgumentError,
      );
    });

    test('should validate span ID is not empty when ending', () async {
      // Act & Assert
      expect(
        () => telemetryService.endSpan(spanId: ''),
        throwsArgumentError,
      );
    });

    test('should validate metric value is not NaN', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordMetric(
          name: 'test-metric',
          metricType: 'counter',
          value: double.nan,
        ),
        throwsArgumentError,
      );
    });

    test('should validate metric value is not infinite', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordMetric(
          name: 'test-metric',
          metricType: 'counter',
          value: double.infinity,
        ),
        throwsArgumentError,
      );
    });

    test('should validate timing duration is not negative', () async {
      // Act & Assert
      expect(
        () => telemetryService.recordTiming(
          name: 'query-latency',
          duration: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });
}
