/// Live CRUD latency benchmark against ODBC_TEST_DSN (SQL Server Estacao).
///
/// Run:
///   RUN_PERF_TESTS=1 dart test test/performance/crud_latency_benchmark_test.dart --reporter expanded
library;

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

const _table = 'bench_crud_latency';
const _rowByRowCount = 100;
const _bulkInsertCount = 5000;
const _selectRowCount = 5000;
const _updateDeleteCount = 100;
const _bulkParallelism = 4;
const _poolSize = 4;

void main() {
  loadTestEnv();

  test(
    'CRUD latency benchmark (prints timings to stdout)',
    () async {
      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null || dsn.isEmpty) {
        print('SKIP: ODBC_TEST_DSN not configured');
        return;
      }

      final native = NativeOdbcConnection();
      if (!native.initialize()) {
        print('SKIP: native initialize failed: ${native.getError()}');
        return;
      }

      final connId = native.connect(dsn);
      if (connId == 0) {
        print('SKIP: connect failed: ${native.getError()}');
        return;
      }

      try {
        _setupTable(native, connId);
        final results = <_BenchRow>[
          await _benchInsertRowByRow(native, connId),
        ];
        _truncateTable(native, connId);

        results.addAll(await _benchInsertBulk(native, connId));
        _truncateTable(native, connId);

        results
          ..add(await _benchInsertBulkParallel(native, dsn))
          ..add(await _benchSelectBuffered(native, connId))
          ..add(await _benchSelectStreaming(native, connId))
          ..add(await _benchSelectColumnar(native, connId))
          ..add(await _benchUpdatePrepared(native, connId))
          ..add(await _benchDeletePrepared(native, connId));

        _printReport(results);
      } finally {
        native
          ..executeQueryParams(
            connId,
            'DROP TABLE IF EXISTS $_table',
            [],
          )
          ..disconnect(connId);
      }
    },
    skip: runPerformanceTests
        ? null
        : 'Set RUN_PERF_TESTS=1 to run live CRUD benchmark',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _setupTable(NativeOdbcConnection native, int connId) {
  native
    ..executeQueryParams(connId, 'DROP TABLE IF EXISTS $_table', [])
    ..executeQueryParams(
      connId,
      'CREATE TABLE $_table '
      '(id INT NOT NULL PRIMARY KEY, val NVARCHAR(50) NOT NULL)',
      [],
    );
}

void _truncateTable(NativeOdbcConnection native, int connId) {
  native.executeQueryParams(connId, 'DELETE FROM $_table', []);
}

Future<_BenchRow> _benchInsertRowByRow(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'INSERT INTO $_table (id, val) VALUES (?, ?)';
  final stmt = native.prepare(connId, sql);
  if (stmt == 0) {
    return const _BenchRow(
      'INSERT',
      'row-by-row prepared',
      _rowByRowCount,
      -1,
      -1,
    );
  }

  final sw = Stopwatch()..start();
  for (var i = 1; i <= _rowByRowCount; i++) {
    native.executePrepared(
      stmt,
      [ParamValueInt32(i), const ParamValueString('row')],
      0,
      1000,
    );
  }
  sw.stop();
  native.closeStatement(stmt);

  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'INSERT',
    'row-by-row prepared',
    _rowByRowCount,
    ms / _rowByRowCount,
    _rowByRowCount / (sw.elapsedMicroseconds / 1e6),
  );
}

Future<List<_BenchRow>> _benchInsertBulk(
  NativeOdbcConnection native,
  int connId,
) async {
  final builder = BulkInsertBuilder()
    ..table(_table)
    ..addColumn('id', BulkColumnType.i32)
    ..addColumn('val', BulkColumnType.text, maxLen: 50);

  for (var i = 1; i <= _bulkInsertCount; i++) {
    builder.addRow([i, 'bulk']);
  }

  final buildSw = Stopwatch()..start();
  final payload = builder.build();
  buildSw.stop();

  final ffiSw = Stopwatch()..start();
  final inserted = native.bulkInsertArray(
    connId,
    _table,
    const ['id', 'val'],
    payload,
    _bulkInsertCount,
  );
  ffiSw.stop();

  if (inserted < 0) {
    return [
      _BenchRow(
        'INSERT',
        'bulk array build',
        _bulkInsertCount,
        buildSw.elapsedMicroseconds / 1000.0,
        _bulkInsertCount / (buildSw.elapsedMicroseconds / 1e6),
      ),
      const _BenchRow('INSERT', 'bulk array FFI', _bulkInsertCount, -1, -1),
    ];
  }

  final buildMs = buildSw.elapsedMicroseconds / 1000.0;
  final ffiMs = ffiSw.elapsedMicroseconds / 1000.0;
  return [
    _BenchRow(
      'INSERT',
      'bulk array build',
      _bulkInsertCount,
      buildMs,
      _bulkInsertCount / (buildSw.elapsedMicroseconds / 1e6),
    ),
    _BenchRow(
      'INSERT',
      'bulk array FFI',
      inserted,
      ffiMs / inserted,
      inserted / (ffiSw.elapsedMicroseconds / 1e6),
    ),
  ];
}

Future<_BenchRow> _benchInsertBulkParallel(
  NativeOdbcConnection native,
  String dsn,
) async {
  final pool = native.createConnectionPool(dsn, _poolSize);
  if (pool == null) {
    return const _BenchRow(
      'INSERT',
      'bulk parallel pool x$_bulkParallelism',
      _bulkInsertCount,
      -1,
      -1,
    );
  }

  try {
    final builder = BulkInsertBuilder()
      ..table(_table)
      ..addColumn('id', BulkColumnType.i32)
      ..addColumn('val', BulkColumnType.text, maxLen: 50);

    for (var i = 1; i <= _bulkInsertCount; i++) {
      builder.addRow([i, 'bulk-parallel']);
    }

    final payload = builder.build();
    final sw = Stopwatch()..start();
    final inserted = pool.bulkInsertParallel(
      _table,
      const ['id', 'val'],
      payload,
      parallelism: _bulkParallelism,
    );
    sw.stop();

    if (inserted < 0) {
      return const _BenchRow(
        'INSERT',
        'bulk parallel pool x$_bulkParallelism',
        _bulkInsertCount,
        -1,
        -1,
      );
    }

    final ms = sw.elapsedMicroseconds / 1000.0;
    return _BenchRow(
      'INSERT',
      'bulk parallel pool x$_bulkParallelism',
      inserted,
      ms / inserted,
      inserted / (sw.elapsedMicroseconds / 1e6),
    );
  } finally {
    pool.close();
  }
}

Future<_BenchRow> _benchSelectBuffered(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'SELECT id, val FROM $_table ORDER BY id';
  final sw = Stopwatch()..start();
  final buf = native.executeQueryParams(connId, sql, []);
  sw.stop();

  if (buf == null) {
    return const _BenchRow(
      'SELECT',
      'buffered row-major',
      _selectRowCount,
      -1,
      -1,
    );
  }

  final decoded = BinaryProtocolParser.parse(buf);
  final rows = decoded.rowCount;
  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'SELECT',
    'buffered row-major',
    rows,
    ms,
    rows / (sw.elapsedMicroseconds / 1e6),
  );
}

Future<_BenchRow> _benchSelectStreaming(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'SELECT id, val FROM $_table ORDER BY id';
  var rows = 0;
  final sw = Stopwatch()..start();
  await for (final chunk in native.streamQueryBatched(
    connId,
    sql,
  )) {
    rows += chunk.rowCount;
  }
  sw.stop();

  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'SELECT',
    'streaming batched',
    rows,
    ms,
    rows / (sw.elapsedMicroseconds / 1e6),
  );
}

Future<_BenchRow> _benchSelectColumnar(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'SELECT id, val FROM $_table ORDER BY id';
  final sw = Stopwatch()..start();
  final buf = native.executeQueryParams(
    connId,
    sql,
    [],
    resultEncoding: ResultEncoding.columnar,
  );
  sw.stop();

  if (buf == null) {
    return const _BenchRow(
      'SELECT',
      'columnar buffered',
      _selectRowCount,
      -1,
      -1,
    );
  }

  final decoded = BinaryProtocolParser.parse(buf);
  final rows = decoded.rowCount;
  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'SELECT',
    'columnar buffered',
    rows,
    ms,
    rows / (sw.elapsedMicroseconds / 1e6),
  );
}

Future<_BenchRow> _benchUpdatePrepared(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'UPDATE $_table SET val = ? WHERE id = ?';
  final stmt = native.prepare(connId, sql);
  if (stmt == 0) {
    return const _BenchRow(
      'UPDATE',
      'prepared row-by-row',
      _updateDeleteCount,
      -1,
      -1,
    );
  }

  final sw = Stopwatch()..start();
  for (var i = 1; i <= _updateDeleteCount; i++) {
    native.executePrepared(
      stmt,
      [const ParamValueString('updated'), ParamValueInt32(i)],
      0,
      1000,
    );
  }
  sw.stop();
  native.closeStatement(stmt);

  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'UPDATE',
    'prepared row-by-row',
    _updateDeleteCount,
    ms / _updateDeleteCount,
    _updateDeleteCount / (sw.elapsedMicroseconds / 1e6),
  );
}

Future<_BenchRow> _benchDeletePrepared(
  NativeOdbcConnection native,
  int connId,
) async {
  const sql = 'DELETE FROM $_table WHERE id = ?';
  final stmt = native.prepare(connId, sql);
  if (stmt == 0) {
    return const _BenchRow(
      'DELETE',
      'prepared row-by-row',
      _updateDeleteCount,
      -1,
      -1,
    );
  }

  final sw = Stopwatch()..start();
  for (var i = 1; i <= _updateDeleteCount; i++) {
    native.executePrepared(stmt, [ParamValueInt32(i)], 0, 1000);
  }
  sw.stop();
  native.closeStatement(stmt);

  final ms = sw.elapsedMicroseconds / 1000.0;
  return _BenchRow(
    'DELETE',
    'prepared row-by-row',
    _updateDeleteCount,
    ms / _updateDeleteCount,
    _updateDeleteCount / (sw.elapsedMicroseconds / 1e6),
  );
}

void _printReport(List<_BenchRow> rows) {
  print('\n=== CRUD Latency Benchmark (odbc_fast / Dart native) ===\n');
  print(
    '${'op'.padRight(8)} | ${'method'.padRight(22)} | '
    '${'rows/ops'.padLeft(8)} | ${'avg ms'.padLeft(10)} | '
    '${'throughput'.padLeft(14)}',
  );
  print('${'-' * 8}-+-${'-' * 22}-+-${'-' * 8}-+-${'-' * 10}-+-${'-' * 14}');
  for (final r in rows) {
    final throughput = r.throughputPerSec < 0
        ? 'FAILED'
        : r.op == 'SELECT'
            ? '${r.throughputPerSec.toStringAsFixed(0)} rows/s'
            : '${r.throughputPerSec.toStringAsFixed(0)} ops/s';
    final avgMs = r.avgMs < 0 ? 'FAILED' : r.avgMs.toStringAsFixed(3);
    print(
      '${r.op.padRight(8)} | ${r.method.padRight(22)} | '
      '${r.count.toString().padLeft(8)} | ${avgMs.padLeft(10)} | '
      '${throughput.padLeft(14)}',
    );
  }
  print('');
}

class _BenchRow {
  const _BenchRow(
    this.op,
    this.method,
    this.count,
    this.avgMs,
    this.throughputPerSec,
  );

  final String op;
  final String method;
  final int count;
  final double avgMs;
  final double throughputPerSec;
}
