// Comprehensive demo: connect, query, metrics.
// For streaming, transactions, pool, etc. see savepoint_demo and async_demo.
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Run: dart run example/main.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/di/service_locator.dart';
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
      'Create .env with ODBC_TEST_DSN=... or set env var. '
      'Skipping DB-dependent examples.',
    );
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  await runExampleMetrics(service);
  await runExampleBasic(service, dsn);

  AppLogger.info('All examples completed.');
}

Future<void> runExampleMetrics(OdbcService service) async {
  AppLogger.info('=== Example: Metrics (no DB required) ===');

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

Future<void> runExampleBasic(OdbcService service, String dsn) async {
  AppLogger.info('=== Example: Basic connect, executeQuery, disconnect ===');

  final initResult = await service.initialize();
  if (!initResult.isSuccess()) {
    initResult.fold((_) {}, (f) => AppLogger.severe('Init failed: $f'));
    return;
  }

  final connResult = await service.connect(dsn);
  await connResult.fold(
    (connection) async {
      AppLogger.info('Connected: ${connection.id}');

      final queryResult = await service.executeQuery(
        "SELECT 1 AS id, 'hello' AS msg",
        connectionId: connection.id,
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
      }
    },
  );
}
