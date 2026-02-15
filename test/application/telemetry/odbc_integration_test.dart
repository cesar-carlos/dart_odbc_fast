import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:test/test.dart';

/// Mock repository for integration testing.
class MockRepository implements ITelemetryRepository {
  final List<Trace> exportedTraces = [];
  final List<Span> exportedSpans = [];
  final List<Metric> exportedMetrics = [];
  final List<TelemetryEvent> exportedEvents = [];

  @override
  Future<void> exportTrace(Trace trace) async {
    exportedTraces.add(trace);
  }

  @override
  Future<void> exportSpan(Span span) async {
    exportedSpans.add(span);
  }

  @override
  Future<void> exportMetric(Metric metric) async {
    exportedMetrics.add(metric);
  }

  @override
  Future<void> exportEvent(TelemetryEvent event) async {
    exportedEvents.add(event);
  }

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    final trace = exportedTraces.firstWhere(
      (t) => t.traceId == traceId,
      orElse: () => throw StateError('Trace not found: $traceId'),
    );
    exportedTraces[exportedTraces.indexOf(trace)] = trace.copyWith(
      endTime: endTime,
      attributes: {...trace.attributes, ...attributes},
    );
  }

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    final span = exportedSpans.firstWhere(
      (s) => s.spanId == spanId,
      orElse: () => throw StateError('Span not found: $spanId'),
    );
    exportedSpans[exportedSpans.indexOf(span)] = span.copyWith(
      endTime: endTime,
      attributes: {...span.attributes, ...attributes},
    );
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}

  void reset() {
    exportedTraces.clear();
    exportedSpans.clear();
    exportedMetrics.clear();
    exportedEvents.clear();
  }
}

/// Simple integration tests for SimpleTelemetryService.
///
/// Tests verify that telemetry traces, spans, metrics, and events
/// are properly recorded through the repository.
void main() {
  late SimpleTelemetryService service;
  late MockRepository mockRepository;

  setUp(() {
    mockRepository = MockRepository();
    service = SimpleTelemetryService(mockRepository);
  });

  tearDown(() async {
    await service.shutdown();
    mockRepository.reset();
  });

  group('SimpleTelemetryService - Integration Tests', () {
    test('should record traces for operations', () async {
      // Act
      final trace = service.startTrace('test-operation');
      await service.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.exportedTraces.length, equals(1));
      expect(
        mockRepository.exportedTraces.first.name,
        equals('test-operation'),
      );
      expect(mockRepository.exportedTraces.first.endTime, isNotNull);
      expect(service.serviceName, equals('odbc_fast'));
    });

    test('should record spans with parent relationships', () async {
      // Arrange
      final trace = service.startTrace('base-operation');

      // Act
      final span = service.startSpan(
        parentId: trace.traceId,
        spanName: 'child-operation',
      );
      await service.endSpan(spanId: span.spanId);
      await service.endTrace(traceId: trace.traceId);

      // Assert
      expect(mockRepository.exportedTraces.length, equals(1));
      expect(mockRepository.exportedSpans.length, equals(1));
      expect(
        mockRepository.exportedSpans.first.parentSpanId,
        equals(trace.traceId),
      );
      expect(mockRepository.exportedSpans.first.traceId, equals(trace.traceId));
      expect(
        mockRepository.exportedSpans.first.name,
        equals('child-operation'),
      );
    });

    test('should record metrics', () async {
      // Act
      await service.recordMetric(
        name: 'test-metric',
        metricType: 'counter',
        value: 42,
      );

      // Assert
      expect(mockRepository.exportedMetrics.length, equals(1));
      expect(mockRepository.exportedMetrics.first.name, equals('test-metric'));
      expect(mockRepository.exportedMetrics.first.value, equals(42.0));
    });

    test('should record events', () async {
      // Act
      await service.recordEvent(
        name: 'test-event',
        severity: TelemetrySeverity.warn,
        message: 'Test event message',
        context: {'key': 'value'},
      );

      // Assert
      expect(mockRepository.exportedEvents.length, equals(1));
      expect(mockRepository.exportedEvents.first.name, equals('test-event'));
      expect(
        mockRepository.exportedEvents.first.severity,
        equals(TelemetrySeverity.warn),
      );
      expect(
        mockRepository.exportedEvents.first.message,
        equals('Test event message'),
      );
    });

    test('should merge attributes when ending trace', () async {
      // Arrange
      final trace = service.startTrace('test-op');

      // Act
      await service.endTrace(
        traceId: trace.traceId,
        attributes: {'status': 'completed', 'items': '5'},
      );

      // Assert
      expect(
        mockRepository.exportedTraces.first.attributes.containsKey('status'),
        isTrue,
      );
      expect(
        mockRepository.exportedTraces.first.attributes['status'],
        equals('completed'),
      );
      expect(
        mockRepository.exportedTraces.first.attributes.containsKey('items'),
        isTrue,
      );
    });

    test('should merge attributes when ending span', () async {
      // Arrange
      final trace = service.startTrace('base-op');
      final span = service.startSpan(
        parentId: trace.traceId,
        spanName: 'child-span',
        initialAttributes: {'initial': 'value'},
      );

      // Act
      await service.endSpan(
        spanId: span.spanId,
        attributes: {'final': 'result'},
      );

      // Assert
      expect(
        mockRepository.exportedSpans.first.attributes.containsKey('initial'),
        isTrue,
      );
      expect(
        mockRepository.exportedSpans.first.attributes.containsKey('final'),
        isTrue,
      );
    });

    test('should generate unique IDs for traces', () {
      // Act
      final trace1 = service.startTrace('op1');
      final trace2 = service.startTrace('op2');

      // Assert
      expect(trace1.traceId, isNot(equals(trace2.traceId)));
    });

    test('should generate unique IDs for spans', () {
      // Arrange
      final trace = service.startTrace('base');

      // Act
      final span1 = service.startSpan(
        parentId: trace.traceId,
        spanName: 'span1',
      );
      final span2 = service.startSpan(
        parentId: trace.traceId,
        spanName: 'span2',
      );

      // Assert
      expect(span1.spanId, isNot(equals(span2.spanId)));
      expect(span1.traceId, equals(trace.traceId));
      expect(span2.traceId, equals(trace.traceId));
    });

    test('should handle gauge metrics', () async {
      // Act
      await service.recordGauge(
        name: 'active-connections',
        value: 5,
      );

      // Assert
      expect(mockRepository.exportedMetrics.length, equals(1));
      expect(
        mockRepository.exportedMetrics.first.name,
        equals('active-connections'),
      );
      expect(mockRepository.exportedMetrics.first.unit, equals('count'));
    });

    test('should handle timing metrics', () async {
      // Act
      await service.recordTiming(
        name: 'query-latency',
        duration: const Duration(milliseconds: 150),
      );

      // Assert
      expect(mockRepository.exportedMetrics.length, equals(1));
      expect(
        mockRepository.exportedMetrics.first.name,
        equals('query-latency'),
      );
      expect(mockRepository.exportedMetrics.first.value, equals(150.0));
      expect(mockRepository.exportedMetrics.first.unit, equals('ms'));
    });
  });
}
