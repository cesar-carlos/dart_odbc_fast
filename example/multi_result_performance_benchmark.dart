// Live multi-result performance sample (buffered + streaming).
// Run: dart run example/multi_result_performance_benchmark.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN. Optional:
//   ODBC_MULTI_BENCH_ROWS      — rows per SELECT (default 5000)
//   ODBC_MULTI_BENCH_SETS      — SELECT statements in the batch (default 3)
//   ODBC_MULTI_BENCH_WARMUP    — warmup iterations (default 1)
//   ODBC_MULTI_BENCH_ITERS     — timed iterations (default 5)
//   ODBC_MULTI_BENCH_FETCH     — streamQueryMulti fetchSize (default 1000)
//   ODBC_MULTI_BENCH_CHUNK     — streamQueryMulti chunkSize (default 65536)

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final rows = _envInt('ODBC_MULTI_BENCH_ROWS', 5000);
  final sets = _envInt('ODBC_MULTI_BENCH_SETS', 3);
  final warmup = _envInt('ODBC_MULTI_BENCH_WARMUP', 1);
  final iters = _envInt('ODBC_MULTI_BENCH_ITERS', 5);
  final fetchSize = _envInt('ODBC_MULTI_BENCH_FETCH', 1000);
  final chunkSize = _envInt('ODBC_MULTI_BENCH_CHUNK', 64 * 1024);
  final sql = _buildBatchSql(rows: rows, sets: sets);

  final locator = ServiceLocator()..initialize(useAsync: true);
  final sync = locator.syncService;
  final asyncSvc = locator.asyncService;

  final init = await sync.initialize();
  if (init.isError()) {
    init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
    return;
  }
  final asyncInit = await asyncSvc.initialize();
  if (asyncInit.isError()) {
    asyncInit.fold((_) {}, (e) => AppLogger.severe('Async init failed: $e'));
    return;
  }

  final syncConn = (await sync.connect(dsn)).getOrNull();
  final asyncConn = (await asyncSvc.connect(dsn)).getOrNull();
  if (syncConn == null || asyncConn == null) {
    AppLogger.severe('Connect failed');
    return;
  }

  try {
    stdout
      ..writeln(
        'multi-result bench rows=$rows sets=$sets '
        'fetchSize=$fetchSize chunkSize=$chunkSize '
        'warmup=$warmup iters=$iters',
      )
      ..writeln('SQL preview: ${sql.replaceAll('\n', ' ').trim()}');
    AppLogger.info(
      'multi-result bench rows=$rows sets=$sets '
      'fetchSize=$fetchSize chunkSize=$chunkSize '
      'warmup=$warmup iters=$iters',
    );

    await _warmup(
      sync,
      syncConn.id,
      asyncSvc,
      asyncConn.id,
      sql,
      warmup,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    stdout.writeln('warmup done');

    final buffered = await _timeBuffered(sync, syncConn.id, sql, iters);
    final streamSync = await _timeStream(
      sync,
      syncConn.id,
      sql,
      iters,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );
    final streamAsync = await _timeStream(
      asyncSvc,
      asyncConn.id,
      sql,
      iters,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    );

    _printResult('executeQueryMultiFull (sync)', buffered);
    _printResult('streamQueryMulti (sync)', streamSync);
    _printResult('streamQueryMulti (async)', streamAsync);
  } finally {
    await sync.disconnect(syncConn.id);
    await asyncSvc.disconnect(asyncConn.id);
    locator.shutdown();
  }
}

String _buildBatchSql({required int rows, required int sets}) {
  // Prefer the same table as other heavy benches.
  // Override with ODBC_BENCH_TABLE.
  final table = Platform.environment['ODBC_BENCH_TABLE']?.trim();
  final tableName = (table == null || table.isEmpty) ? 'Produto' : table;
  final parts = <String>[
    for (var i = 0; i < sets; i++) 'SELECT TOP ($rows) * FROM $tableName',
  ];
  return parts.join(';\n');
}

Future<void> _warmup(
  IOdbcService sync,
  String syncId,
  IOdbcService asyncSvc,
  String asyncId,
  String sql,
  int warmup, {
  required int fetchSize,
  required int chunkSize,
}) async {
  for (var i = 0; i < warmup; i++) {
    await sync.executeQueryMultiFull(syncId, sql);
    await for (final _ in sync.streamQueryMulti(
      syncId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    )) {}
    await for (final _ in asyncSvc.streamQueryMulti(
      asyncId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    )) {}
  }
}

Future<_Timed> _timeBuffered(
  IOdbcService service,
  String connectionId,
  String sql,
  int iters,
) async {
  final samples = <int>[];
  var lastItems = 0;
  var lastRows = 0;
  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    final result = await service.executeQueryMultiFull(connectionId, sql);
    sw.stop();
    final items = result.getOrNull();
    if (items == null) {
      result.fold((_) {}, (e) => AppLogger.severe('buffered failed: $e'));
      break;
    }
    lastItems = items.items.length;
    lastRows = items.resultSets.fold<int>(
      0,
      (sum, rs) => sum + rs.rowCount,
    );
    samples.add(sw.elapsedMilliseconds);
  }
  return _Timed(samples: samples, items: lastItems, rows: lastRows);
}

Future<_Timed> _timeStream(
  IOdbcService service,
  String connectionId,
  String sql,
  int iters, {
  required int fetchSize,
  required int chunkSize,
}) async {
  final samples = <int>[];
  var lastItems = 0;
  var lastRows = 0;
  for (var i = 0; i < iters; i++) {
    final sw = Stopwatch()..start();
    var items = 0;
    var rows = 0;
    var failed = false;
    await for (final chunk in service.streamQueryMulti(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
    )) {
      chunk.fold(
        (item) {
          items++;
          if (item.isResultSet) {
            rows += item.resultSet?.rowCount ?? 0;
          }
        },
        (e) {
          failed = true;
          AppLogger.severe('stream failed: $e');
        },
      );
      if (failed) {
        break;
      }
    }
    sw.stop();
    if (failed) {
      break;
    }
    lastItems = items;
    lastRows = rows;
    samples.add(sw.elapsedMilliseconds);
  }
  return _Timed(samples: samples, items: lastItems, rows: lastRows);
}

void _printResult(String name, _Timed timed) {
  if (timed.samples.isEmpty) {
    stdout.writeln('$name: no samples');
    AppLogger.warning('$name: no samples');
    return;
  }
  final sorted = List<int>.of(timed.samples)..sort();
  final median = sorted[sorted.length ~/ 2];
  final best = sorted.first;
  final worst = sorted.last;
  final rowsPerSec =
      timed.rows > 0 && median > 0 ? (timed.rows * 1000 / median).round() : 0;
  final line = '$name: median=${median}ms best=${best}ms worst=${worst}ms '
      'items=${timed.items} rows=${timed.rows} rows/s≈$rowsPerSec '
      'samples=${timed.samples}';
  stdout.writeln(line);
  AppLogger.info(line);
}

int _envInt(String key, int fallback) {
  final raw = Platform.environment[key];
  if (raw == null || raw.isEmpty) {
    return fallback;
  }
  return int.tryParse(raw) ?? fallback;
}

class _Timed {
  const _Timed({
    required this.samples,
    required this.items,
    required this.rows,
  });

  final List<int> samples;
  final int items;
  final int rows;
}
