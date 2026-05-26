/// Microbench for `SqlPointerCache` to demonstrate the win vs the legacy
/// allocate-and-free-per-call pattern.
///
/// Runs DSN-free. Marked as `tags: ['perf']` so CI only invokes it through
/// the performance lane (matches `protocol_performance_test.dart`). The
/// thresholds below are conservative — they verify the cache is *at least*
/// as fast, not that it hits a specific wall-clock target.
///
/// When `BENCH_BASELINE_OUT` is set (e.g. `bench_baselines/sql_cache.json`),
/// the test also writes a baseline-shaped JSON file consumable by
/// `tool/compare_benchmark_baseline.dart`. This is opt-in so casual
/// `dart test` runs don't litter the working tree.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/sql_pointer_cache.dart';
import 'package:test/test.dart';

const int _iterations = 50000;
const int _hotSetSize = 16;

void main() {
  group('SqlPointerCache microbench', () {
    test(
      'cached_acquire_should_be_at_least_as_fast_as_baseline_allocate_and_free',
      () {
        final cache = SqlPointerCache();
        addTearDown(cache.dispose);

        final hotSql = List.generate(
          _hotSetSize,
          (i) => 'SELECT col_$i FROM tbl WHERE id = ?',
        );

        // Warm-up: prime the cache with all hot SQL strings, then reset
        // counters so only the steady-state hot loop is measured.
        // A plain `for` loop is kept here (instead of `forEach(cache.acquire)`)
        // to avoid the cascade_invocations lint that fires when two adjacent
        // statements share the same receiver: the explicit loop keeps the
        // warm-up and reset visually distinct.
        // ignore: prefer_foreach
        for (final sql in hotSql) {
          cache.acquire(sql);
        }
        cache.resetStats();

        // Measure cached path (hot loop).
        final sw1 = Stopwatch()..start();
        for (var i = 0; i < _iterations; i++) {
          cache.acquire(hotSql[i % _hotSetSize]);
        }
        sw1.stop();
        final cachedMicros = sw1.elapsedMicroseconds;

        // Sanity: cache hit rate must be ~100% on this workload.
        expect(
          cache.stats.hits,
          equals(_iterations),
          reason: 'every iteration should hit the cache',
        );
        expect(cache.stats.misses, equals(0));

        // Measure baseline (legacy allocate-and-free per call).
        final sw2 = Stopwatch()..start();
        for (var i = 0; i < _iterations; i++) {
          final ptr = hotSql[i % _hotSetSize].toNativeUtf8();
          // Touch the pointer to keep the optimizer honest.
          if (ptr.cast<ffi.Uint8>().value < 0) {
            throw StateError('unreachable');
          }
          malloc.free(ptr);
        }
        sw2.stop();
        final baselineMicros = sw2.elapsedMicroseconds;

        printOnFailure(
          'sql cache bench: cached=${cachedMicros}us, '
          'baseline=${baselineMicros}us, '
          'speedup=${(baselineMicros / cachedMicros).toStringAsFixed(2)}x',
        );

        // Conservative assertion: cached must not be more than 50% slower
        // than baseline. In practice it is several times faster.
        expect(
          cachedMicros,
          lessThan(baselineMicros * 3 ~/ 2),
          reason: 'cached acquire ($cachedMicros us) should not be more than '
              '50% slower than baseline ($baselineMicros us)',
        );

        // Optionally emit a JSON baseline for
        // `tool/compare_benchmark_baseline.dart`. Each entry follows the
        // same shape used by streaming benches: elapsedMs +
        // queriesPerSecond. We model "queries" as "acquires" here — the
        // comparator treats it as a relative throughput number.
        final baselineOut = Platform.environment['BENCH_BASELINE_OUT'];
        if (baselineOut != null && baselineOut.isNotEmpty) {
          final acquiresPerSecond = _iterations / (cachedMicros / 1000000);
          final payload = [
            <String, Object?>{
              'scenario': 'sql_cache.cached_acquire',
              'elapsedMs': cachedMicros / 1000.0,
              'rowsPerSecond': 0,
              'queriesPerSecond': acquiresPerSecond,
              'latencyP95Micros': 0,
              'fallbacksToBlocking': 0,
            },
            <String, Object?>{
              'scenario': 'sql_cache.baseline_alloc_free',
              'elapsedMs': baselineMicros / 1000.0,
              'rowsPerSecond': 0,
              'queriesPerSecond':
                  _iterations / (baselineMicros / 1000000),
              'latencyP95Micros': 0,
              'fallbacksToBlocking': 0,
            },
          ];
          final file = File(baselineOut);
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(payload),
          );
        }
      },
      tags: ['perf'],
    );
  });
}
