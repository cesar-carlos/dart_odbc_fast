// Comprehensive demo: connect, query, transactions, streaming,
// catalog, pool, bulk insert.
// For v0.3.0 features (savepoints, retry, timeouts, connection builder),
// see: example/savepoint_demo.dart, example/retry_demo.dart,
// example/connection_builder_demo.dart
// See example/README.md for index of all examples.

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

bool _shouldRunBulkInsertDemo() {
  final v = Platform.environment['ODBC_EXAMPLE_ENABLE_BULK'] ??
      Platform.environment['ODBC_FAST_ENABLE_BULK'];
  if (v == null) return false;
  return v == '1' || v.toLowerCase() == 'true' || v.toLowerCase() == 'yes';
}

void main() async {
  AppLogger.initialize();

  final locator = ServiceLocator();
  // initialize() returns void, so cascade cannot be used in assignment.
  // ignore: cascade_invocations
  locator.initialize();

  final dsn = _getExampleDsn();
  final skipDb = dsn == null || dsn.isEmpty;

  if (skipDb) {
    AppLogger.warning(
      'ODBC_TEST_DSN (or ODBC_DSN) not set. '
      'Create .env with ODBC_TEST_DSN=... or set env var. '
      'Skipping DB-dependent examples.',
    );
  }

  await runExampleMetrics(locator);

  if (skipDb) {
    AppLogger.info(
      'Done. Set ODBC_TEST_DSN in .env to run connect/query examples.',
    );
    return;
  }

  await runExampleBasic(locator, dsn);
  await runExampleStreaming(locator, dsn);
  await runExampleTransactions(locator, dsn);
  await runExampleParamsAndPrepared(locator, dsn);
  await runExampleCatalog(locator, dsn);
  await runExamplePool(locator, dsn);
  if (_shouldRunBulkInsertDemo()) {
    await runExampleBulkInsert(locator, dsn);
  } else {
    AppLogger.info(
      'Skipping bulk insert demo. Set ODBC_EXAMPLE_ENABLE_BULK=1 to run it.',
    );
  }
  AppLogger.info('All examples completed.');
}

Future<void> runExampleMetrics(ServiceLocator locator) async {
  AppLogger.info('=== Example: Metrics (no DB required) ===');

  final service = locator.service;
  final initResult = await service.initialize();
  initResult.fold(
    (_) => AppLogger.info('ODBC environment initialized'),
    (f) {
      AppLogger.severe('Init failed: $f');
      return;
    },
  );

  final metricsResult = await service.getMetrics();
  metricsResult.fold(
    (m) {
      AppLogger.info(
        'Metrics: queries=${m.queryCount} errors=${m.errorCount} '
        'uptime_secs=${m.uptimeSecs} avg_latency_ms=${m.avgLatencyMillis}',
      );
    },
    (f) => AppLogger.warning('Metrics unavailable: $f'),
  );
}

Future<void> runExampleBasic(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Basic connect, executeQuery, disconnect ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  await connResult.fold(
    (connection) async {
      AppLogger.info('Connected: ${connection.id}');

      final queryResult = await service.executeQuery(
        connection.id,
        "SELECT 1 AS id, 'hello' AS msg",
      );
      queryResult.fold(
        (qr) {
          AppLogger.info(
            'Query: columns=${qr.columns} rowCount=${qr.rowCount}',
          );
          for (var i = 0; i < qr.rows.length; i++) {
            AppLogger.fine('  row ${i + 1}: ${qr.rows[i]}');
          }
        },
        (e) => AppLogger.severe('Query failed: $e'),
      );

      final discResult = await service.disconnect(connection.id);
      discResult.fold(
        (_) => AppLogger.info('Disconnected'),
        (e) => AppLogger.warning('Disconnect error: $e'),
      );
    },
    (error) async {
      if (error is OdbcError) {
        AppLogger.severe('Connect failed: ${error.message}');
        if (error.sqlState != null) {
          AppLogger.fine('  SQLSTATE: ${error.sqlState}');
        }
        if (error.nativeCode != null) {
          AppLogger.fine('  Native: ${error.nativeCode}');
        }
      } else {
        AppLogger.severe('Connect failed: $error');
      }
    },
  );
}

Future<void> runExampleStreaming(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Streaming query ===');

  final native = locator.nativeConnection;
  if (!native.initialize()) {
    AppLogger.severe('ODBC init failed');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    final se = native.getStructuredError();
    if (se != null) {
      AppLogger.severe('Connect failed: ${se.message}');
    } else {
      AppLogger.severe('Connect failed: ${native.getError()}');
    }
    return;
  }

  AppLogger.info('Connected (ID: $connId). Streaming…');

  try {
    const sql = "SELECT 1 AS id, 'a' AS x UNION ALL SELECT 2, 'b'";
    var chunkIndex = 0;
    await for (final chunk
        in native.streamQueryBatched(connId, sql, fetchSize: 100)) {
      chunkIndex++;
      AppLogger.fine('Chunk $chunkIndex: ${chunk.columnCount} cols, '
          '${chunk.rowCount} rows');
      for (final row in chunk.rows) {
        AppLogger.fine('  $row');
      }
    }
    AppLogger.info('Streaming done.');
  } on Exception catch (e) {
    AppLogger.severe('Stream error: $e');
  } finally {
    if (native.disconnect(connId)) {
      AppLogger.info('Disconnected.');
    } else {
      AppLogger.warning('Disconnect error: ${native.getError()}');
    }
  }
}

Future<void> runExampleTransactions(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Transaction (begin / commit) ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  if (connResult.exceptionOrNull() != null) {
    connResult.fold((_) {}, (e) => AppLogger.severe('Connect failed: $e'));
    return;
  }

  Connection? connection;
  connResult.fold((c) => connection = c, (_) {});

  if (connection == null) return;

  final beginResult = await service.beginTransaction(
    connection!.id,
    IsolationLevel.readCommitted,
  );

  beginResult.fold(
    (txnId) async {
      AppLogger.info('Transaction started: txnId=$txnId');
      final commitResult =
          await service.commitTransaction(connection!.id, txnId);
      commitResult.fold(
        (_) => AppLogger.info('Committed.'),
        (e) => AppLogger.warning('Commit failed: $e'),
      );
    },
    (e) => AppLogger.severe('Begin transaction failed: $e'),
  );

  final discResult = await service.disconnect(connection!.id);
  discResult.fold(
    (_) => AppLogger.info('Disconnected.'),
    (e) => AppLogger.warning('Disconnect error: $e'),
  );
}

Future<void> runExampleParamsAndPrepared(
  ServiceLocator locator,
  String dsn,
) async {
  AppLogger.info('=== Example: Params + Prepared statements ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  Connection? connection;
  connResult.fold((c) => connection = c, (e) {
    AppLogger.severe('Connect failed: $e');
  });
  if (connection == null) return;

  try {
    final paramsResult = await service.executeQueryParams(
      connection!.id,
      'SELECT ? AS a, ? AS b, ? AS c',
      [1, 'hello', null],
    );
    paramsResult.fold(
      (qr) => AppLogger.info(
        'executeQueryParams: columns=${qr.columns} rowCount=${qr.rowCount}',
      ),
      (e) => AppLogger.warning('executeQueryParams failed: $e'),
    );

    final stmtIdResult = await service.prepare(
      connection!.id,
      'SELECT ? AS id, ? AS msg',
    );

    await stmtIdResult.fold((stmtId) async {
      final execPrepared = await service.executePrepared(
        connection!.id,
        stmtId,
        [123, 'prepared-ok'],
        null,
      );
      execPrepared.fold(
        (qr) => AppLogger.info(
          'executePrepared: columns=${qr.columns} rowCount=${qr.rowCount}',
        ),
        (e) => AppLogger.warning('executePrepared failed: $e'),
      );

      final closeResult = await service.closeStatement(connection!.id, stmtId);
      closeResult.fold(
        (_) => AppLogger.info('Statement closed.'),
        (e) => AppLogger.warning('Close statement failed: $e'),
      );
    }, (e) async {
      AppLogger.warning('Prepare failed: $e');
    });

    final multiResult = await service.executeQueryMulti(
      connection!.id,
      'SELECT 1 AS a; SELECT 2 AS b;',
    );
    multiResult.fold(
      (qr) => AppLogger.info(
        'executeQueryMulti: columns=${qr.columns} rowCount=${qr.rowCount}',
      ),
      (e) => AppLogger.warning('executeQueryMulti failed: $e'),
    );
  } finally {
    final discResult = await service.disconnect(connection!.id);
    discResult.fold(
      (_) => AppLogger.info('Disconnected.'),
      (e) => AppLogger.warning('Disconnect error: $e'),
    );
  }
}

Future<void> runExampleCatalog(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Catalog (tables / columns / type info) ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  Connection? connection;
  connResult.fold((c) => connection = c, (e) {
    AppLogger.severe('Connect failed: $e');
  });
  if (connection == null) return;

  try {
    final tablesResult = await service.catalogTables(connection!.id);
    String? firstTableName;
    tablesResult.fold((qr) {
      AppLogger.info('catalogTables: rowCount=${qr.rowCount}');
      if (qr.rows.isNotEmpty) {
        AppLogger.fine('catalogTables first row: ${qr.rows.first}');
        for (final v in qr.rows.first) {
          if (v is String && v.trim().isNotEmpty) {
            firstTableName = v.trim();
            break;
          }
        }
      }
    }, (e) {
      AppLogger.warning('catalogTables failed: $e');
    });

    if (firstTableName != null) {
      final colsResult = await service.catalogColumns(
        connection!.id,
        firstTableName!,
      );
      colsResult.fold(
        (qr) => AppLogger.info(
          'catalogColumns($firstTableName): rowCount=${qr.rowCount}',
        ),
        (e) => AppLogger.warning('catalogColumns failed: $e'),
      );
    } else {
      AppLogger.info(
        'No table name detected from catalogTables; skipping columns demo.',
      );
    }

    final typeInfoResult = await service.catalogTypeInfo(connection!.id);
    typeInfoResult.fold(
      (qr) => AppLogger.info('catalogTypeInfo: rowCount=${qr.rowCount}'),
      (e) => AppLogger.warning('catalogTypeInfo failed: $e'),
    );
  } finally {
    final discResult = await service.disconnect(connection!.id);
    discResult.fold(
      (_) => AppLogger.info('Disconnected.'),
      (e) => AppLogger.warning('Disconnect error: $e'),
    );
  }
}

Future<void> runExamplePool(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Connection Pool ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  const maxSize = 4;
  final poolIdResult = await service.poolCreate(dsn, maxSize);
  int? poolId;
  poolIdResult.fold(
    (id) => poolId = id,
    (e) => AppLogger.severe('poolCreate failed: $e'),
  );
  if (poolId == null) return;

  final health = await service.poolHealthCheck(poolId!);
  health.fold(
    (ok) => AppLogger.info('poolHealthCheck: $ok'),
    (e) => AppLogger.warning('poolHealthCheck failed: $e'),
  );

  final state = await service.poolGetState(poolId!);
  state.fold(
    (s) => AppLogger.info('poolGetState: size=${s.size} idle=${s.idle}'),
    (e) => AppLogger.warning('poolGetState failed: $e'),
  );

  final pooledConn = await service.poolGetConnection(poolId!);
  Connection? connection;
  pooledConn.fold(
    (c) => connection = c,
    (e) => AppLogger.severe('poolGetConnection failed: $e'),
  );

  if (connection != null) {
    final q = await service.executeQuery(connection!.id, 'SELECT 1');
    q.fold(
      (qr) => AppLogger.info('Pooled query ok: rowCount=${qr.rowCount}'),
      (e) => AppLogger.warning('Pooled query failed: $e'),
    );

    final release = await service.poolReleaseConnection(connection!.id);
    release.fold(
      (_) => AppLogger.info('poolReleaseConnection ok'),
      (e) => AppLogger.warning('poolReleaseConnection failed: $e'),
    );
  }

  final close = await service.poolClose(poolId!);
  close.fold(
    (_) => AppLogger.info('poolClose ok'),
    (e) => AppLogger.warning('poolClose failed: $e'),
  );
}

Future<void> runExampleBulkInsert(ServiceLocator locator, String dsn) async {
  AppLogger.info('=== Example: Bulk Insert (binary payload) ===');

  final service = locator.service;
  final initResult = await service.initialize();
  if (initResult.exceptionOrNull() != null) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  Connection? connection;
  connResult.fold((c) => connection = c, (e) {
    AppLogger.severe('Connect failed: $e');
  });
  if (connection == null) return;

  try {
    final builder = BulkInsertBuilder()
        .table('odbc_fast_bulk_demo')
        .addColumn('id', BulkColumnType.i32)
        .addColumn('name', BulkColumnType.text, maxLen: 64)
        .addRow([1, 'alice']).addRow([2, 'bob']);

    final result = await service.bulkInsert(
      connection!.id,
      builder.tableName,
      builder.columnNames,
      builder.build(),
      builder.rowCount,
    );

    result.fold(
      (inserted) => AppLogger.info('Bulk insert inserted=$inserted'),
      (e) => AppLogger.warning(
        'Bulk insert failed (ensure table exists): $e',
      ),
    );
  } finally {
    final discResult = await service.disconnect(connection!.id);
    discResult.fold(
      (_) => AppLogger.info('Disconnected.'),
      (e) => AppLogger.warning('Disconnect error: $e'),
    );
  }
}
