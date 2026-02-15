// Streaming queries demo - reading large sets of
// results in chunks
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart run example/streaming_demo.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/odbc_fast.dart';

const _envPath = '.env';

String _exampleEnvPath() =>
    '${Directory.current.path}${Platform.pathSeparator}$_envPath';

String? _getExampleDsn() {
  final path = _exampleEnvPath();
  final file = File(path);
  if (file.existsSync()) {
    final env = DotEnv(includePlatformEnvironment: true)..load([path]);
    final v = env['ODBC_TEST_DSN'];
    if (v != null && v.isNotEmpty) return v;
  }
  return Platform.environment['ODBC_TEST_DSN'] ??
      Platform.environment['ODBC_DSN'];
}

void main() async {
  AppLogger.initialize();

  final dsn = _getExampleDsn();
  final skipDb = dsn == null || dsn.isEmpty;

  if (skipDb) {
    AppLogger.warning(
      'ODBC_TEST_DSN (or ODBC_DSN) not set. '
      'Create .env with ODBC_TEST_DSN=... or set the environment variable. '
      'Skipping DB-dependent examples.',
    );
    return;
  }

  final native = NativeOdbcConnection();

  final initResult = native.initialize();
  if (!initResult) {
    AppLogger.severe('ODBC environment initialization failed');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connection failed: ${native.getError()}');
    return;
  }

  AppLogger.info('Connected: $connId');

  // Create test table with large dataset
  await _createStreamingTestTable(native, connId);

  // Demonstrate streaming query with batching
  await _demoStreamingBatched(native, connId);

  // Demonstrate streaming query with custom chunk size
  await _demoStreamingCustomChunk(native, connId);

  native.disconnect(connId);
  AppLogger.info('Disconnected');
  AppLogger.info('All examples completed.');
}

Future<void> _createStreamingTestTable(
  NativeOdbcConnection native,
  int connId,
) async {
  const createTableSql = '''
    IF OBJECT_ID('streaming_test_table', 'U') IS NOT NULL
      DROP TABLE streaming_test_table;

    CREATE TABLE streaming_test_table (
      id INT IDENTITY(1,1) PRIMARY KEY,
      name NVARCHAR(100) NOT NULL,
      value DECIMAL(10,2),
      created_at DATETIME DEFAULT GETDATE()
    )
  ''';

  AppLogger.fine('Creating streaming test table');

  final stmt = native.prepare(connId, createTableSql);
  if (stmt == 0) {
    AppLogger.warning('Prepare failed: ${native.getError()}');
    return;
  }

  final result = native.executePrepared(stmt, const <ParamValue>[], 0, 1000);
  if (result == null) {
    AppLogger.warning('Table creation failed: ${native.getError()}');
    native.closeStatement(stmt);
    return;
  }

  native.closeStatement(stmt);
  AppLogger.fine('Table created');

  // Insert test data
  AppLogger.info('Inserting test data...');
  const insertSql =
      'INSERT INTO streaming_test_table (name, value) VALUES (?, ?)';
  final insertStmt = native.prepare(connId, insertSql);

  if (insertStmt == 0) {
    AppLogger.warning('Insert prepare failed: ${native.getError()}');
    return;
  }

  for (var i = 1; i <= 5000; i++) {
    final result = native.executePrepared(
      insertStmt,
      [
        ParamValueString('Item_$i'),
        ParamValueDecimal((i * 1.5).toStringAsFixed(2)),
      ],
      0,
      1000,
    );

    if (result == null) {
      AppLogger.warning('Insert failed $i: ${native.getError()}');
      break;
    }

    if (i % 1000 == 0) {
      AppLogger.fine('$i rows inserted');
    }
  }

  native.closeStatement(insertStmt);
  AppLogger.info('Test data inserted (5000 Rows)');
}

Future<void> _demoStreamingBatched(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info('=== Example: Streaming query with batching ===');

  const selectSql = 'SELECT id, name, value FROM streaming_test_table';
  final stream = native.streamQueryBatched(
    connId,
    selectSql,
  );

  var totalRows = 0;
  var chunkCount = 0;
  final stopwatch = Stopwatch()..start();

  try {
    await for (final chunk in stream) {
      chunkCount++;
      final rowCount = chunk.rowCount;
      totalRows += rowCount;

      AppLogger.fine('Chunk $chunkCount: $rowCount Rows');

      // Process chunk data here
      // In a real application, you would transform or aggregate data
      // Example:
      // final rows = chunk.rows;
      // for (final row in rows) {
      //   final id = row[0] as int;
      //   final name = row[1] as String;
      // }
    }
  } on Object catch (e) {
    AppLogger.warning('Stream error: $e');
  }

  stopwatch.stop();

  AppLogger.info('Streaming completed:');
  AppLogger.info('  Total chunks: $chunkCount');
  AppLogger.info('  Total rows: $totalRows');
  AppLogger.info('  Elapsed time: ${stopwatch.elapsedMilliseconds}ms');
  final throughput = totalRows / (stopwatch.elapsedMilliseconds / 1000);
  AppLogger.info(
    '  Throughput: ${throughput.toStringAsFixed(2)} rows/sec',
  );
}

Future<void> _demoStreamingCustomChunk(
  NativeOdbcConnection native,
  int connId,
) async {
  AppLogger.info(
    '=== Example: Streaming query with custom chunk size ===',
  );

  const selectSql = 'SELECT id, name, value FROM streaming_test_table';
  final stream = native.streamQuery(
    connId,
    selectSql,
    chunkSize: 500,
  );

  var totalRows = 0;
  var chunkCount = 0;

  try {
    await for (final chunk in stream) {
      chunkCount++;
      final rowCount = chunk.rowCount;
      totalRows += rowCount;

      AppLogger.fine(
        'Chunk $chunkCount: $rowCount Rows (custom chunk size)',
      );
    }
  } on Object catch (e) {
    AppLogger.warning('Stream error: $e');
  }

  AppLogger.info('Streaming with custom chunk completed:');
  AppLogger.info('  Total chunks: $chunkCount');
  AppLogger.info('  Total rows: $totalRows');
  final avgRows = totalRows / chunkCount;
  AppLogger.info(
    '  Average rows per chunk: ${avgRows.toStringAsFixed(1)}',
  );
}
