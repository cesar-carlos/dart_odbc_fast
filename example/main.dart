// Main example: high-level API with OdbcService (sync mode).
// Run: dart run example/main.dart

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) {
    init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
    return;
  }

  final connResult = await service.connect(dsn);
  final conn = connResult.getOrNull();
  if (conn == null) {
    connResult.fold((_) {}, (e) => AppLogger.severe('Connect failed: $e'));
    return;
  }

  AppLogger.info('Connected: ${conn.id}');

  try {
    final query = await service.executeQuery(
      'SELECT 1 AS id, 2 AS value',
      connectionId: conn.id,
    );

    query.fold(
      (rows) => AppLogger.info(
        'Query OK: rowCount=${rows.rowCount}, columns=${rows.columns}',
      ),
      (e) => AppLogger.severe('Query failed: $e'),
    );

    final metrics = await service.getMetrics();
    metrics.fold(
      (m) => AppLogger.info(
        'Metrics: queries=${m.queryCount}, errors=${m.errorCount}, '
        'avgLatencyMs=${m.avgLatencyMillis}',
      ),
      (e) => AppLogger.warning('Metrics unavailable: $e'),
    );
  } finally {
    final disconnect = await service.disconnect(conn.id);
    disconnect.fold(
      (_) => AppLogger.info('Disconnected'),
      (e) => AppLogger.warning('Disconnect error: $e'),
    );
  }
}
