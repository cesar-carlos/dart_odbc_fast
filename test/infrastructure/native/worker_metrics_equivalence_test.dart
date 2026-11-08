import 'dart:math';

import 'package:test/test.dart';

import '../../helpers/worker_metrics_fixture.dart';

void main() {
  test('should_discard_cached_percentiles_when_workers_are_recreated', () {
    final first = WorkerMetricsFixture(1);
    final oldStats = first.connection.getWorkerPoolStats();
    first.dispose();
    // Recreate the same number of samples without taking a snapshot while
    // the pool is empty. Sample versions collide across worker generations.
    final replacement = WorkerMetricsFixture(
      1,
      connection: first.connection,
      sampleOffset: 10000,
    );
    addTearDown(replacement.dispose);
    final stats = replacement.connection.getWorkerPoolStats();
    expect(stats.latencyP95Micros, greaterThan(oldStats.latencyP95Micros));
    expect(stats.latencyP95Micros, stats.workers.single.latencyP95Micros);
    expect(stats.queueWaitP95Micros, stats.workers.single.queueWaitP95Micros);
    expect(stats.executionP95Micros, stats.workers.single.executionP95Micros);
  });

  test('should_match_sorted_percentiles_for_varied_samples', () {
    final fixture = WorkerMetricsFixture(1);
    addTearDown(fixture.dispose);
    final random = Random(602);
    for (final size in [0, 1, 2, 19, 20, 21, 255, 256, 1024, 16384]) {
      final randomValues =
          List.generate(size, (_) => random.nextInt(2001) - 1000);
      for (final values in [
        randomValues,
        List<int>.filled(size, 7),
        List.generate(size, (i) => i),
        List.generate(size, (i) => size - i),
      ]) {
        final original = List<int>.of(values);
        final sorted = List<int>.of(values)..sort();
        for (final percentile in [0, 50, 95, 100]) {
          final expected =
              size == 0 ? 0 : sorted[((size - 1) * percentile / 100).ceil()];
          expect(fixture.percentile(values, percentile), expected);
          expect(values, original, reason: 'Sample order must be preserved');
        }
      }
    }
  });

  for (final count in [1, 4, 16, 64]) {
    test('should_preserve_worker_aggregates_and_refresh_samples_with_$count',
        () {
      final fixture = WorkerMetricsFixture(count);
      addTearDown(fixture.dispose);
      final stats = fixture.connection.getWorkerPoolStats();
      final sum = count * (count + 1) ~/ 2;
      expect(stats.workerCount, count);
      expect(stats.workers.length, count);
      expect(
        [
          stats.activeRequests,
          stats.totalRouted,
          stats.completedRequests,
          stats.failedRequests,
          stats.timeouts,
          stats.fallbacksToBlocking,
          stats.cancelAttempts,
          stats.cancelSucceeded,
          stats.cancelUnsupported,
        ],
        everyElement(sum),
      );
      expect(stats.pendingRequests, 0);
      final latencies = <int>[];
      final queues = <int>[];
      final executions = <int>[];
      for (var i = 0; i < count; i++) {
        for (var j = 0; j < 256; j++) {
          latencies.add((j * 73 + i * 31) % 1009);
          queues.add((j * 19 + i * 7) % 101);
          executions.add((j * 53 + i * 13) % 503);
        }
      }
      int average(List<int> values) =>
          values.fold(0, (a, b) => a + b) ~/ (2 * sum);
      int p95(List<int> values) =>
          (values..sort())[((values.length - 1) * .95).ceil()];
      expect(stats.latencyAvgMicros, average(latencies));
      expect(stats.queueWaitAvgMicros, average(queues));
      expect(stats.executionAvgMicros, average(executions));
      expect(stats.latencyP95Micros, p95(latencies));
      expect(stats.queueWaitP95Micros, p95(queues));
      expect(stats.executionP95Micros, p95(executions));
      expect(stats.latencyMaxMicros, latencies.last);
      expect(stats.queueWaitMaxMicros, queues.last);
      expect(stats.executionMaxMicros, executions.last);
      expect(
        fixture.connection.getWorkerPoolStats().latencyP95Micros,
        stats.latencyP95Micros,
      );
      for (var i = 0; i < 256; i++) {
        fixture.update(1200);
      }
      final updated = fixture.connection.getWorkerPoolStats();
      expect(updated.latencyP95Micros, 1200);
      expect(updated.queueWaitP95Micros, 400);
      expect(updated.executionP95Micros, 600);
    });
  }
}
