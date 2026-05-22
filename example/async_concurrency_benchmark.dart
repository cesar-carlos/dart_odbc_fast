// Async concurrency benchmark for worker pool, native pool and streaming.
// Run: dart run example/async_concurrency_benchmark.dart
//
// Columnar scenarios use the native async execute path when available; if the
// engine returns no async request id, the client falls back to blocking
// encode paths (see `fallbacksToBlocking` in JSON output).
//
// Tunables: `ODBC_BENCH_CONNECTION_COUNT`, `ODBC_BENCH_QUERY_COUNT`
// (defaults 4, 24).

import 'dart:convert';
import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) return;

  final connectionCount = _envInt('ODBC_BENCH_CONNECTION_COUNT', 4);
  final queryCount = _envInt('ODBC_BENCH_QUERY_COUNT', 24);
  const poolSize = 4;
  const maxInFlight = 4;

  final query = _envOr('ODBC_BENCH_QUERY', 'SELECT 1 AS value');
  final streamQuery = _envOr('ODBC_BENCH_STREAM_QUERY', query);
  final results = [
    await _benchWorkerPool(
      label: 'workerCount=1',
      workerCount: 1,
      dsn: dsn,
      connectionCount: connectionCount,
      queryCount: queryCount,
      query: query,
    ),
    await _benchWorkerPool(
      label: 'workerCount=4',
      workerCount: 4,
      dsn: dsn,
      connectionCount: connectionCount,
      queryCount: queryCount,
      query: query,
    ),
    await _benchWorkerPool(
      label: 'workerCount=4 columnar',
      workerCount: 4,
      dsn: dsn,
      connectionCount: connectionCount,
      queryCount: queryCount,
      query: query,
      resultEncoding: ResultEncoding.columnar,
    ),
    await _benchWorkerPool(
      label: 'workerCount=4 columnar compressed',
      workerCount: 4,
      dsn: dsn,
      connectionCount: connectionCount,
      queryCount: queryCount,
      query: query,
      resultEncoding: ResultEncoding.columnarCompressed,
    ),
    await _benchNativePool(
      dsn: dsn,
      poolSize: poolSize,
      taskCount: queryCount,
      maxInFlight: maxInFlight,
      query: query,
    ),
    await _benchPreparedReuse(
      dsn: dsn,
      queryCount: queryCount,
      query: _envOr('ODBC_BENCH_PREPARED_QUERY', query),
    ),
    await _benchStreaming(
      dsn: dsn,
      workerCount: 4,
      query: streamQuery,
    ),
  ];

  _writeResults(results);
}

Future<_BenchmarkResult> _benchWorkerPool({
  required String label,
  required int workerCount,
  required String dsn,
  required int connectionCount,
  required int queryCount,
  required String query,
  ResultEncoding resultEncoding = ResultEncoding.rowMajor,
}) async {
  final async = AsyncNativeOdbcConnection(
    workerCount: workerCount,
    maxPendingRequests: queryCount * 8,
    requestTimeout: const Duration(seconds: 60),
  );
  await async.initialize();
  final connections = <int>[];

  try {
    for (var i = 0; i < connectionCount; i++) {
      connections.add(await async.connect(dsn));
    }

    final elapsed = await _measure(() {
      return Future.wait(
        List.generate(queryCount, (index) {
          final connId = connections[index % connections.length];
          return _runQuery(
            async,
            connId,
            query,
            resultEncoding: resultEncoding,
          );
        }),
      );
    });

    final stats = async.getWorkerPoolStats();
    return _BenchmarkResult(
      scenario: label,
      workers: workerCount,
      poolSize: null,
      maxInFlight: queryCount,
      queryCount: queryCount,
      elapsedMs: elapsed.inMilliseconds,
      rowsOrBatches: queryCount,
      resultEncoding: resultEncoding,
      stats: stats,
    );
  } finally {
    for (final connId in connections) {
      await async.disconnect(connId);
    }
    async.dispose();
  }
}

Future<_BenchmarkResult> _benchNativePool({
  required String dsn,
  required int poolSize,
  required int taskCount,
  required int maxInFlight,
  required String query,
}) async {
  final async = AsyncNativeOdbcConnection(
    workerCount: 4,
    maxPendingRequests: poolSize * 4,
    requestTimeout: const Duration(seconds: 60),
  );
  await async.initialize();
  var poolId = 0;

  try {
    poolId = await async.poolCreate(dsn, poolSize);
    var poolConnectMicros = 0;
    var poolQueryMicros = 0;
    final elapsed = await _measure(() {
      return _runLimited<void>(taskCount, maxInFlight, (index) async {
        final checkout = Stopwatch()..start();
        final connId = await async.poolGetConnection(poolId);
        checkout.stop();
        poolConnectMicros += checkout.elapsedMicroseconds;
        final querySw = Stopwatch()..start();
        try {
          await _runQuery(async, connId, query);
        } finally {
          querySw.stop();
          poolQueryMicros += querySw.elapsedMicroseconds;
          await async.poolReleaseConnection(connId);
        }
      });
    });

    final stats = async.getWorkerPoolStats();
    return _BenchmarkResult(
      scenario: 'native pool',
      workers: 4,
      poolSize: poolSize,
      maxInFlight: maxInFlight,
      queryCount: taskCount,
      elapsedMs: elapsed.inMilliseconds,
      rowsOrBatches: taskCount,
      resultEncoding: ResultEncoding.rowMajor,
      stats: stats,
      poolConnectMs: (poolConnectMicros / 1000).round(),
      poolQueryMs: (poolQueryMicros / 1000).round(),
    );
  } finally {
    if (poolId > 0) {
      await async.poolClose(poolId);
    }
    async.dispose();
  }
}

Future<_BenchmarkResult> _benchPreparedReuse({
  required String dsn,
  required int queryCount,
  required String query,
}) async {
  final async = AsyncNativeOdbcConnection(
    requestTimeout: const Duration(seconds: 60),
  );
  await async.initialize();
  var connId = 0;
  var stmtId = 0;

  try {
    connId = await async.connect(dsn);
    stmtId = await async.prepare(connId, query);
    if (stmtId == 0) {
      throw StateError('Prepare failed: ${await async.getError()}');
    }

    final elapsed = await _measure(() async {
      for (var i = 0; i < queryCount; i++) {
        final data = await async.executePrepared(
          stmtId,
          const <ParamValue>[],
          0,
          1000,
        );
        if (data == null) {
          throw StateError(
            'Prepared execute failed: ${await async.getError()}',
          );
        }
      }
    });

    return _BenchmarkResult(
      scenario: 'prepared reuse',
      workers: 1,
      poolSize: null,
      maxInFlight: 1,
      queryCount: queryCount,
      elapsedMs: elapsed.inMilliseconds,
      rowsOrBatches: queryCount,
      resultEncoding: ResultEncoding.rowMajor,
      stats: async.getWorkerPoolStats(),
    );
  } finally {
    if (stmtId > 0) {
      await async.closeStatement(stmtId);
    }
    if (connId > 0) {
      await async.disconnect(connId);
    }
    async.dispose();
  }
}

Future<_BenchmarkResult> _benchStreaming({
  required String dsn,
  required int workerCount,
  required String query,
}) async {
  final async = AsyncNativeOdbcConnection(
    workerCount: workerCount,
    requestTimeout: const Duration(seconds: 60),
  );
  await async.initialize();
  var connId = 0;

  try {
    connId = await async.connect(dsn);
    var batches = 0;
    final elapsed = await _measure(() async {
      await for (final _ in async.streamQueryBatched(connId, query)) {
        batches++;
      }
    });

    return _BenchmarkResult(
      scenario: 'streaming batched',
      workers: workerCount,
      poolSize: null,
      maxInFlight: 1,
      queryCount: 1,
      elapsedMs: elapsed.inMilliseconds,
      rowsOrBatches: batches,
      resultEncoding: ResultEncoding.rowMajor,
      stats: async.getWorkerPoolStats(),
    );
  } finally {
    if (connId > 0) {
      await async.disconnect(connId);
    }
    async.dispose();
  }
}

Future<void> _runQuery(
  AsyncNativeOdbcConnection async,
  int connId,
  String query, {
  ResultEncoding resultEncoding = ResultEncoding.rowMajor,
}) async {
  final result = await async.executeQueryParams(
    connId,
    query,
    const <ParamValue>[],
    resultEncoding: resultEncoding,
  );
  if (result == null) {
    throw StateError('Query failed: ${await async.getError()}');
  }
}

Future<Duration> _measure(Future<void> Function() action) async {
  final stopwatch = Stopwatch()..start();
  await action();
  stopwatch.stop();
  return stopwatch.elapsed;
}

Future<List<T>> _runLimited<T>(
  int count,
  int maxInFlight,
  Future<T> Function(int index) task,
) async {
  final results = List<T?>.filled(count, null);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= count) return;
      results[index] = await task(index);
    }
  }

  await Future.wait(List.generate(maxInFlight, (_) => worker()));
  return results.cast<T>();
}

String _envOr(String name, String fallback) {
  final value = Platform.environment[name];
  if (value != null && value.isNotEmpty) return value;
  return fallback;
}

int _envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return fallback;
  return int.tryParse(raw) ?? fallback;
}

double _throughputPerSecond(int units, int elapsedMs) {
  if (elapsedMs <= 0 || units <= 0) return 0;
  return units * 1000.0 / elapsedMs;
}

void _writeResults(List<_BenchmarkResult> results) {
  final format = _envOr('ODBC_BENCH_OUTPUT', 'text').toLowerCase();
  final outFile = Platform.environment['ODBC_BENCH_OUT_FILE'];
  final content = switch (format) {
    'json' => const JsonEncoder.withIndent('  ').convert(
        results.map((result) => result.toJson()).toList(growable: false),
      ),
    'csv' => _toCsv(results),
    _ => _toText(results),
  };

  if (outFile != null && outFile.isNotEmpty) {
    File(outFile).writeAsStringSync(content);
    stdout.writeln('Benchmark results written to $outFile');
  } else {
    stdout.writeln(content);
  }
}

String _toText(List<_BenchmarkResult> results) {
  return results
      .map(
        (result) => '${result.scenario}: ${result.elapsedMs} ms, '
            'workers=${result.workers}, poolSize=${result.poolSize ?? 0}, '
            'maxInFlight=${result.maxInFlight}, '
            'encoding=${result.resultEncoding.name}, '
            'units=${result.rowsOrBatches}, '
            'routed=${result.stats.totalRouted}, '
            'timeouts=${result.stats.timeouts}, '
            'fallbacks=${result.stats.fallbacksToBlocking}',
      )
      .join('\n');
}

String _toCsv(List<_BenchmarkResult> results) {
  const header = 'scenario,workers,poolSize,maxInFlight,queryCount,elapsedMs,'
      'resultEncoding,'
      'rowsOrBatches,queriesPerSecond,rowsPerSecond,poolConnectMs,poolQueryMs,'
      'totalRouted,timeouts,fallbacksToBlocking,latencyP95Micros';
  final rows = results.map((result) {
    return [
      result.scenario,
      result.workers,
      result.poolSize ?? '',
      result.maxInFlight,
      result.queryCount,
      result.elapsedMs,
      result.resultEncoding.name,
      result.rowsOrBatches,
      result.queriesPerSecond.toStringAsFixed(2),
      result.rowsPerSecond.toStringAsFixed(2),
      result.poolConnectMs ?? '',
      result.poolQueryMs ?? '',
      result.stats.totalRouted,
      result.stats.timeouts,
      result.stats.fallbacksToBlocking,
      result.stats.latencyP95Micros,
    ].join(',');
  });
  return [header, ...rows].join('\n');
}

final class _BenchmarkResult {
  const _BenchmarkResult({
    required this.scenario,
    required this.workers,
    required this.poolSize,
    required this.maxInFlight,
    required this.queryCount,
    required this.elapsedMs,
    required this.rowsOrBatches,
    required this.resultEncoding,
    required this.stats,
    this.poolConnectMs,
    this.poolQueryMs,
  });

  final String scenario;
  final int workers;
  final int? poolSize;
  final int maxInFlight;
  final int queryCount;
  final int elapsedMs;
  final int rowsOrBatches;
  final ResultEncoding resultEncoding;
  final AsyncWorkerPoolStats stats;
  final int? poolConnectMs;
  final int? poolQueryMs;

  double get queriesPerSecond => _throughputPerSecond(queryCount, elapsedMs);

  /// Approximate rows/s when each completed unit is one logical row
  /// (worker pool, prepared, native pool). Streaming uses batch count as
  /// throughput units.
  double get rowsPerSecond {
    if (scenario == 'streaming batched') {
      return _throughputPerSecond(rowsOrBatches, elapsedMs);
    }
    return _throughputPerSecond(queryCount, elapsedMs);
  }

  Map<String, Object?> toJson() {
    return {
      'scenario': scenario,
      'workers': workers,
      'poolSize': poolSize,
      'maxInFlight': maxInFlight,
      'queryCount': queryCount,
      'elapsedMs': elapsedMs,
      'resultEncoding': resultEncoding.name,
      'rowsOrBatches': rowsOrBatches,
      'queriesPerSecond': queriesPerSecond,
      'rowsPerSecond': rowsPerSecond,
      if (poolConnectMs != null) 'poolConnectMs': poolConnectMs,
      if (poolQueryMs != null) 'poolQueryMs': poolQueryMs,
      'totalRouted': stats.totalRouted,
      'completedRequests': stats.completedRequests,
      'failedRequests': stats.failedRequests,
      'timeouts': stats.timeouts,
      'fallbacksToBlocking': stats.fallbacksToBlocking,
      'cancelAttempts': stats.cancelAttempts,
      'latencyAvgMicros': stats.latencyAvgMicros,
      'latencyP95Micros': stats.latencyP95Micros,
      'latencyMaxMicros': stats.latencyMaxMicros,
    };
  }
}
