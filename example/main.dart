// Main example: high-level API with OdbcService (sync mode).
// Run: dart run example/main.dart

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

  final connResult = await service.connect(
    dsn,
    options: const ConnectionOptions(
      loginTimeout: Duration(seconds: 30),
      initialResultBufferBytes: 256 * 1024,
      maxResultBufferBytes: 16 * 1024 * 1024,
      queryTimeout: Duration(seconds: 10),
      autoReconnectOnConnectionLost: true,
      maxReconnectAttempts: 3,
      reconnectBackoff: Duration(seconds: 1),
    ),
  );
  final conn = connResult.getOrNull();
  if (conn == null) {
    connResult.fold((_) {}, (e) => AppLogger.severe('Connect failed: $e'));
    return;
  }

  AppLogger.info('Connected: ${conn.id}');

  try {
    final driver = await service.detectDriver(dsn);
    AppLogger.info('Detected driver: ${driver ?? 'unknown'}');

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

    final named = await service.executeQueryNamed(
      conn.id,
      'SELECT @id AS id, @msg AS msg',
      <String, Object?>{'id': 100, 'msg': 'named'},
    );
    named.fold(
      (rows) => AppLogger.info('Named query OK: rows=${rows.rowCount}'),
      (e) => AppLogger.warning('Named query unavailable: $e'),
    );

    final preparedNamed = await service.prepareNamed(
      conn.id,
      'SELECT @id AS id, @msg AS msg',
    );
    final stmtId = preparedNamed.getOrNull();
    if (stmtId != null) {
      final execPreparedNamed = await service.executePreparedNamed(
        conn.id,
        stmtId,
        <String, Object?>{'id': 200, 'msg': 'prepared-named'},
        null,
      );
      execPreparedNamed.fold(
        (rows) => AppLogger.info(
          'Prepared named OK: rows=${rows.rowCount}',
        ),
        (e) => AppLogger.warning('Prepared named unavailable: $e'),
      );
      await service.closeStatement(conn.id, stmtId);
    } else {
      preparedNamed.fold(
        (_) {},
        (e) => AppLogger.warning('prepareNamed unavailable: $e'),
      );
    }

    final multi = await service.executeQueryMultiFull(
      conn.id,
      'SELECT 1 AS first_value; SELECT 2 AS second_value;',
    );
    multi.fold(
      (m) => AppLogger.info(
        'Multi full OK: items=${m.items.length}, '
        'resultSets=${m.resultSets.length}, rowCounts=${m.rowCounts.length}',
      ),
      (e) => AppLogger.warning('Multi full unavailable: $e'),
    );

    final tables = await service.catalogTables(connectionId: conn.id);
    tables.fold(
      (r) => AppLogger.info('Catalog tables rows=${r.rowCount}'),
      (e) => AppLogger.warning('catalogTables unavailable: $e'),
    );

    final columns = await service.catalogColumns(conn.id, 'simple_test_table');
    columns.fold(
      (r) => AppLogger.info('Catalog columns rows=${r.rowCount}'),
      (e) => AppLogger.warning('catalogColumns unavailable: $e'),
    );

    final typeInfo = await service.catalogTypeInfo(conn.id);
    typeInfo.fold(
      (r) => AppLogger.info('Catalog type info rows=${r.rowCount}'),
      (e) => AppLogger.warning('catalogTypeInfo unavailable: $e'),
    );

    final clearCache = await service.clearStatementCache();
    clearCache.fold(
      (_) => AppLogger.info('Statement cache cleared'),
      (e) => AppLogger.warning('clearStatementCache unavailable: $e'),
    );

    final stmtMetrics = await service.getPreparedStatementsMetrics();
    stmtMetrics.fold(
      (m) => AppLogger.info(
        'Stmt metrics: hitRate=${m.cacheHitRate.toStringAsFixed(2)}%, '
        'prepares=${m.totalPrepares}, executions=${m.totalExecutions}',
      ),
      (e) => AppLogger.warning('Prepared metrics unavailable: $e'),
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
