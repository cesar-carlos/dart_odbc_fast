import 'dart:math';

import 'package:test/test.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';

/// Mock implementation of ITelemetryRepository for unit testing.
///
/// This mock provides detailed tracking of all repository calls.
class MockRepository implements ITelemetryRepository {
  int exportTraceCallCount = 0;
  int exportSpanCallCount = 0;
  int exportMetricCallCount = 0;
  int exportEventCallCount = 0;
  int updateTraceCallCount = 0;
  int updateSpanCallCount = 0;
  int flushCallCount = 0;
  int shutdownCallCount = 0;

  Trace? lastExportedTrace;
  Span? lastExportedSpan;
  Metric? lastExportedMetric;
  TelemetryEvent? lastExportedEvent;

  @override
  Future<void> exportTrace(Trace trace) async {
    exportTraceCallCount++;
    lastExportedTrace = trace;
  }

  @override
  Future<void> exportSpan(Span span) async {
    exportSpanCallCount++;
    lastExportedSpan = span;
  }

  @override
  Future<void> exportMetric(Metric metric) async {
    exportMetricCallCount++;
    lastExportedMetric = metric;
  }

  @override
  Future<void> exportEvent(TelemetryEvent event) async {
    exportEventCallCount++;
    lastExportedEvent = event;
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
    flushCallCount++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCallCount++;
  }

  void reset() {
    exportTraceCallCount = 0;
    exportSpanCallCount = 0;
    exportMetricCallCount = 0;
    exportEventCallCount = 0;
    updateTraceCallCount = 0;
    updateSpanCallCount = 0;
    flushCallCount = 0;
    shutdownCallCount = 0;
    lastExportedTrace = null;
    lastExportedSpan = null;
    lastExportedMetric = null;
    lastExportedEvent = null;
  }
}

void main() {
  group('SimpleTelemetryService - Unit Tests', () {
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

    group('Service Name', () {
      test('should return correct service name', () {
        expect(service.serviceName, equals('odbc_fast'));
      });
    });

    group('Trace Operations', () {
      test('should generate unique trace IDs', () {
        // Act
        final trace1 = service.startTrace('op1');
        final trace2 = service.startTrace('op2');

        // Assert
        expect(trace1.traceId, isNot(equals(trace2.traceId)));
      });

      test('should store active trace internally', () async {
        // Act
        final trace = service.startTrace('test-operation');
        await service.endTrace(traceId: trace.traceId);

        // Try to end same trace again - should throw
        expect(
          () => service.endTrace(traceId: trace.traceId),
          throwsA(isException),
        );
      });

      test('should merge attributes when ending trace', () async {
        // Arrange
        final trace = service.startTrace('test-op');
        final endAttributes = {'key': 'value', 'status': 'completed'};

        // Act
        await service.endTrace(
          traceId: trace.traceId,
          attributes: endAttributes,
        );

        // Assert
        expect(mockRepository.updateTraceCallCount, equals(1));
      });

      test('should throw ArgumentError when operation name is empty', () {
        // Act & Assert
        expect(
          () => service.startTrace(''),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when trace ID is empty on end', () async {
        // Act & Assert
        expect(
          () => service.endTrace(traceId: ''),
          throwsArgumentError,
        );
      });
    });

    group('Span Operations', () {
      test('should link span to trace via parentSpanId', () {
        // Arrange
        final trace = service.startTrace('test-operation');

        // Act
        final span = service.startSpan(
          parentId: trace.traceId,
          spanName: 'test-span',
        );

        // Assert
        expect(span.parentSpanId, equals(trace.traceId));
        expect(span.traceId, equals(trace.traceId));
      });

      test('should store active span internally', () async {
        // Arrange
        final trace = service.startTrace('test-operation');
        final span = service.startSpan(
          parentId: trace.traceId,
          spanName: 'test-span',
        );

        // Act
        await service.endSpan(spanId: span.spanId);

        // Try to end same span again - should throw
        expect(
          () => service.endSpan(spanId: span.spanId),
          throwsA(isException),
        );
      });

      test('should merge attributes when ending span', () async {
        // Arrange
        final trace = service.startTrace('test-op');
        final span = service.startSpan(
          parentId: trace.traceId,
          spanName: 'span1',
          initialAttributes: {'initial': 'value'},
        );
        final endAttributes = {'key': 'value', 'status': 'completed'};

        // Act
        await service.endSpan(
          spanId: span.spanId,
          attributes: endAttributes,
        );

        // Assert
        expect(mockRepository.updateSpanCallCount, equals(1));
      });

      test('should throw ArgumentError when span name is empty', () {
        // Arrange
        final trace = service.startTrace('test-operation');

        // Act & Assert
        expect(
          () => service.startSpan(
            parentId: trace.traceId,
            spanName: '',
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when parent ID is empty', () {
        // Act & Assert
        expect(
          () => service.startSpan(
            parentId: '',
            spanName: 'test-span',
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when span ID is empty on end', () async {
        // Arrange
        final trace = service.startTrace('test-operation');
        final span = service.startSpan(
          parentId: trace.traceId,
          spanName: 'test-span',
        );

        // Act & Assert
        expect(
          () => service.endSpan(spanId: ''),
          throwsArgumentError,
        );
      });
    });

    group('Metric Operations', () {
      test('should export metric with correct data', () async {
        // Arrange
        final now = DateTime.now().toUtc();

        // Act
        await service.recordMetric(
          name: 'test-metric',
          metricType: 'counter',
          value: 42.5,
          unit: 'items',
          attributes: {'key': 'value'},
        );

        // Assert
        expect(mockRepository.exportMetricCallCount, equals(1));
        expect(mockRepository.lastExportedMetric?.name, equals('test-metric'));
        expect(mockRepository.lastExportedMetric?.value, equals(42.5));
        expect(mockRepository.lastExportedMetric?.unit, equals('items'));
        expect(mockRepository.lastExportedMetric?.attributes, equals({'key': 'value'}));

        // Verify timestamp is recent (within 1 second)
        final timestampDiff =
            now.difference(mockRepository.lastExportedMetric!.timestamp!);
        expect(timestampDiff.inSeconds, lessThan(1));
      });

      test('should export gauge with default unit', () async {
        // Act
        await service.recordGauge(
          name: 'active-connections',
          value: 5,
        );

        // Assert
        expect(mockRepository.exportMetricCallCount, equals(1));
        expect(mockRepository.lastExportedMetric?.name, equals('active-connections'));
        expect(mockRepository.lastExportedMetric?.value, equals(5.0));
        expect(mockRepository.lastExportedMetric?.unit, equals('count')); // default
      });

      test('should export timing with milliseconds', () async {
        // Act
        await service.recordTiming(
          name: 'query-latency',
          duration: const Duration(milliseconds: 150),
        );

        // Assert
        expect(mockRepository.exportMetricCallCount, equals(1));
        expect(mockRepository.lastExportedMetric?.name, equals('query-latency'));
        expect(mockRepository.lastExportedMetric?.value, equals(150.0));
        expect(mockRepository.lastExportedMetric?.unit, equals('ms'));
      });

      test('should throw ArgumentError when metric name is empty', () async {
        // Act & Assert
        expect(
          () => service.recordMetric(
            name: '',
            metricType: 'counter',
            value: 42,
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when metric value is NaN', () async {
        // Act & Assert
        expect(
          () => service.recordMetric(
            name: 'test-metric',
            metricType: 'counter',
            value: double.nan,
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when metric value is infinite', () async {
        // Act & Assert
        expect(
          () => service.recordMetric(
            name: 'test-metric',
            metricType: 'counter',
            value: double.infinity,
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when metric unit is empty', () async {
        // Act & Assert
        expect(
          () => service.recordMetric(
            name: 'test-metric',
            metricType: 'counter',
            value: 42,
            unit: '',
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when gauge name is empty', () async {
        // Act & Assert
        expect(
          () => service.recordGauge(name: '', value: 5),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when gauge value is NaN', () async {
        // Act & Assert
        expect(
          () => service.recordGauge(
            name: 'test-gauge',
            value: double.nan,
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when timing name is empty', () async {
        // Act & Assert
        expect(
          () => service.recordTiming(
            name: '',
            duration: const Duration(milliseconds: 100),
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when timing duration is negative', () async {
        // Act & Assert
        expect(
          () => service.recordTiming(
            name: 'test-timing',
            duration: const Duration(milliseconds: -1),
          ),
          throwsArgumentError,
        );
      });
    });

    group('Event Operations', () {
      test('should export event with correct data', () async {
        // Arrange
        final now = DateTime.now().toUtc();

        // Act
        await service.recordEvent(
          name: 'test-event',
          severity: TelemetrySeverity.warn,
          message: 'Test event message',
          context: {'key': 'value', 'count': 42},
        );

        // Assert
        expect(mockRepository.exportEventCallCount, equals(1));
        expect(mockRepository.lastExportedEvent?.name, equals('test-event'));
        expect(mockRepository.lastExportedEvent?.severity, equals(TelemetrySeverity.warn));
        expect(mockRepository.lastExportedEvent?.message, equals('Test event message'));
        expect(mockRepository.lastExportedEvent?.context, equals({'key': 'value', 'count': 42}));

        // Verify timestamp is recent
        final timestampDiff =
            now.difference(mockRepository.lastExportedEvent!.timestamp!);
        expect(timestampDiff.inSeconds, lessThan(1));
      });

      test('should throw ArgumentError when event name is empty', () async {
        // Act & Assert
        expect(
          () => service.recordEvent(
            name: '',
            severity: TelemetrySeverity.info,
            message: 'Test message',
          ),
          throwsArgumentError,
        );
      });

      test('should throw ArgumentError when event message is empty', () async {
        // Act & Assert
        expect(
          () => service.recordEvent(
            name: 'test-event',
            severity: TelemetrySeverity.info,
            message: '',
          ),
          throwsArgumentError,
        );
      });
    });

    group('Service Operations', () {
      test('flush should call repository flush', () async {
        // Act
        await service.flush();

        // Assert
        expect(mockRepository.flushCallCount, equals(1));
      });

      test('shutdown should call repository shutdown', () async {
        // Act
        await service.shutdown();

        // Assert
        expect(mockRepository.shutdownCallCount, greaterThan(0));
      });

      test('should handle multiple sequential operations', () async {
        // Act - Execute multiple operations
        final trace = service.startTrace('test-operation');
        await service.recordMetric(name: 'metric1', metricType: 'counter', value: 1);
        await service.recordEvent(
          name: 'event1',
          severity: TelemetrySeverity.info,
          message: 'Test',
        );

        // Assert
        expect(mockRepository.updateTraceCallCount, equals(0)); // not ended yet
        expect(mockRepository.exportMetricCallCount, equals(1));
        expect(mockRepository.exportEventCallCount, equals(1));
      });

      test('should clean up completed traces from memory', () async {
        // Arrange
        final trace = service.startTrace('test-operation');

        // Act
        await service.endTrace(traceId: trace.traceId);

        // Try to end again - should throw
        expect(
          () => service.endTrace(traceId: trace.traceId),
          throwsA(isException),
          reason: 'Completed trace should be removed from memory',
        );
      });
    });

    group('UUID Generation', () {
      test('should generate unique IDs for traces', () {
        // Act
        final ids = List.generate(
          100,
          (i) => service.startTrace('test-\$i').traceId,
        );

        // Assert - All 100 IDs should be unique
        final uniqueIds = ids.toSet();
        expect(uniqueIds.length, equals(100));
      });

      test('should generate unique IDs for spans', () {
        // Arrange
        final trace = service.startTrace('test');

        // Act
        final ids = List.generate(
          100,
          (i) =>
              service.startSpan(parentId: trace.traceId, spanName: 'test-\$i').spanId,
        );

        // Assert - All 100 IDs should be unique
        final uniqueIds = ids.toSet();
        expect(uniqueIds.length, equals(100));
      });

      test('should generate IDs with hex characters and hyphens', () {
        // Act
        final trace = service.startTrace('test');

        // Assert - ID should contain hex chars (0-9, a-f) and hyphens
        final hexPattern = RegExp(r'^[0-9a-f-]+$');
        final parts = trace.traceId.split('-');

        // All parts should be hex
        for (final part in parts) {
          expect(hexPattern.hasMatch(part), isTrue);
        }
      });
    });
  });
}
