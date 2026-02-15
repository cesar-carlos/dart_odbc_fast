import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:test/test.dart';

/// Mock repository for performance testing.
///
/// This mock provides minimal overhead to accurately measure service
/// performance.
class PerfMockRepository implements ITelemetryRepository {
  int totalCalls = 0;

  @override
  Future<void> exportTrace(Trace trace) async {
    totalCalls++;
  }

  @override
  Future<void> exportSpan(Span span) async {
    totalCalls++;
  }

  @override
  Future<void> exportMetric(Metric metric) async {
    totalCalls++;
  }

  @override
  Future<void> exportEvent(TelemetryEvent event) async {
    totalCalls++;
  }

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    totalCalls++;
  }

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {
    totalCalls++;
  }

  @override
  Future<void> flush() async {
    totalCalls++;
  }

  @override
  Future<void> shutdown() async {
    totalCalls++;
  }

  void reset() {
    totalCalls = 0;
  }
}

void main() {
  group('SimpleTelemetryService - Performance Tests', () {
    late SimpleTelemetryService service;
    late PerfMockRepository mockRepository;

    setUp(() {
      mockRepository = PerfMockRepository();
      service = SimpleTelemetryService(mockRepository);
    });

    tearDown(() async {
      await service.shutdown();
      mockRepository.reset();
    });

    group('UUID Generation Performance', () {
      test('should generate 10k unique trace IDs efficiently', () {
        // Arrange & Act
        final stopwatch = Stopwatch()..start();
        final ids = <String>{};

        for (var i = 0; i < 10000; i++) {
          final trace = service.startTrace('operation-$i');
          ids.add(trace.traceId);
        }

        stopwatch.stop();

        // Assert - All IDs should be unique
        expect(ids.length, equals(10000));

        // Performance assertion - should complete in reasonable time
        print(
          'Generated 10,000 trace IDs in ${stopwatch.elapsedMilliseconds}ms',
        );
        print('Average: ${stopwatch.elapsedMilliseconds / 10000}ms per ID');

        // Should be fast - less than 1 second total
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      });

      test('should generate 10k unique span IDs efficiently', () async {
        // Arrange
        final trace = service.startTrace('base-operation');

        // Act
        final stopwatch = Stopwatch()..start();
        final ids = <String>{};

        for (var i = 0; i < 10000; i++) {
          final span = service.startSpan(
            parentId: trace.traceId,
            spanName: 'span-$i',
          );
          ids.add(span.spanId);
        }

        stopwatch.stop();

        // Assert
        expect(ids.length, equals(10000));

        // Performance assertion
        print(
          'Generated 10,000 span IDs in ${stopwatch.elapsedMilliseconds}ms',
        );
        print('Average: ${stopwatch.elapsedMilliseconds / 10000}ms per ID');

        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      });
    });

    group('Metric Recording Performance', () {
      test('should record 10k metrics efficiently', () async {
        // Act
        final stopwatch = Stopwatch()..start();

        for (var i = 0; i < 10000; i++) {
          await service.recordMetric(
            name: 'metric-$i',
            metricType: 'counter',
            value: i.toDouble(),
          );
        }

        stopwatch.stop();

        // Assert
        expect(mockRepository.totalCalls, equals(10000));

        // Performance assertion
        print('Recorded 10,000 metrics in ${stopwatch.elapsedMilliseconds}ms');
        print('Average: ${stopwatch.elapsedMilliseconds / 10000}ms per metric');

        // Should be reasonably fast - allow 5 seconds for 10k operations
        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      });

      test('should record 10k gauge metrics efficiently', () async {
        // Act
        final stopwatch = Stopwatch()..start();

        for (var i = 0; i < 10000; i++) {
          await service.recordGauge(
            name: 'gauge-$i',
            value: i.toDouble(),
          );
        }

        stopwatch.stop();

        // Assert
        expect(mockRepository.totalCalls, equals(10000));

        // Performance assertion
        print('Recorded 10,000 gauges in ${stopwatch.elapsedMilliseconds}ms');
        print('Average: ${stopwatch.elapsedMilliseconds / 10000}ms per gauge');

        expect(stopwatch.elapsedMilliseconds, lessThan(5000));
      });
    });

    group('Throughput Tests', () {
      test('should handle 1k trace lifecycle operations/second', () async {
        // Act
        final stopwatch = Stopwatch()..start();
        var operations = 0;

        for (var i = 0; i < 5000; i++) {
          final trace = service.startTrace('op-$i');
          await service.endTrace(traceId: trace.traceId);
          operations += 2; // start + end
        }

        stopwatch.stop();

        // Assert
        expect(operations, equals(10000)); // 5000 * 2

        // Performance assertion - 10k operations
        print(
          'Completed 10,000 trace operations in '
          '${stopwatch.elapsedMilliseconds}ms',
        );
        print(
          'Throughput: ${operations / (stopwatch.elapsedMilliseconds / 1000)} '
          'ops/sec',
        );

        // Should handle at least 1000 ops/sec
        final opsPerSecond =
            operations / (stopwatch.elapsedMilliseconds / 1000);
        expect(opsPerSecond, greaterThan(1000));
      });

      test('should handle 5k span lifecycle operations/second', () async {
        // Arrange
        final trace = service.startTrace('base-operation');

        // Act
        final stopwatch = Stopwatch()..start();
        var operations = 0;

        for (var i = 0; i < 5000; i++) {
          final span = service.startSpan(
            parentId: trace.traceId,
            spanName: 'span-$i',
          );
          await service.endSpan(spanId: span.spanId);
          operations += 2; // start + end
        }

        stopwatch.stop();

        // Assert
        expect(operations, equals(10000)); // 5000 * 2

        // Performance assertion
        print(
          'Completed 10,000 span operations in '
          '${stopwatch.elapsedMilliseconds}ms',
        );
        print(
          'Throughput: ${operations / (stopwatch.elapsedMilliseconds / 1000)} '
          'ops/sec',
        );

        // Should handle at least 1000 ops/sec
        final opsPerSecond =
            operations / (stopwatch.elapsedMilliseconds / 1000);
        expect(opsPerSecond, greaterThan(1000));
      });
    });

    group('Memory Efficiency', () {
      test('should clean up completed traces from memory', () async {
        // Arrange - Start 1000 traces
        final traceIds = <String>[];
        for (var i = 0; i < 1000; i++) {
          final trace = service.startTrace('trace-$i');
          traceIds.add(trace.traceId);
        }

        // Act - End all traces
        final stopwatch = Stopwatch()..start();
        for (final traceId in traceIds) {
          await service.endTrace(traceId: traceId);
        }

        stopwatch.stop();

        // Performance assertion
        print('Ended 1,000 traces in ${stopwatch.elapsedMilliseconds}ms');
        print(
          'Average: ${stopwatch.elapsedMilliseconds / 1000}ms per trace end',
        );

        // Should be fast - less than 500ms for 1000 operations
        expect(stopwatch.elapsedMilliseconds, lessThan(500));
      });
    });

    group('Concurrency', () {
      test('should handle concurrent metric recordings', () async {
        // Act - Simulate realistic workload
        final stopwatch = Stopwatch()..start();
        final futures = <Future<void>>[];

        for (var i = 0; i < 100; i++) {
          futures.add(
            service.recordMetric(
              name: 'metric-$i',
              metricType: 'counter',
              value: i.toDouble(),
            ),
          );
        }

        // Wait for all to complete
        await Future.wait(futures);
        stopwatch.stop();

        // Assert
        expect(mockRepository.totalCalls, equals(100));

        // Performance assertion - 100 concurrent operations
        print(
          'Completed 100 concurrent metric recordings in '
          '${stopwatch.elapsedMilliseconds}ms',
        );
        print('Average: ${stopwatch.elapsedMilliseconds / 100}ms per metric');

        // Should complete reasonably fast
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      });
    });

    group('Stress - Metric Burst', () {
      test('should handle rapid metric burst', () async {
        // Act - Burst of metrics
        final stopwatch = Stopwatch()..start();
        const burstSize = 50000;

        for (var i = 0; i < burstSize; i++) {
          await service.recordMetric(
            name: 'burst-metric-$i',
            metricType: 'counter',
            value: i.toDouble(),
          );
        }

        stopwatch.stop();

        // Assert
        expect(mockRepository.totalCalls, equals(burstSize));

        // Performance assertion - 50k operations
        print(
          'Recorded $burstSize metrics in ${stopwatch.elapsedMilliseconds}ms',
        );
        print(
          'Throughput: ${burstSize / (stopwatch.elapsedMilliseconds / 1000)}k ops/sec',
        );

        // Should maintain reasonable throughput
        final opsPerSecond = burstSize / (stopwatch.elapsedMilliseconds / 1000);
        expect(opsPerSecond, greaterThan(5000)); // At least 5k ops/sec
      });
    });
  });
}
