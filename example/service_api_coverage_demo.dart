// Service API coverage demo (DB-dependent).
// Run: dart run example/service_api_coverage_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
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

  try {
    await _setupTable(service, conn.id);
    await _demoExecuteQueryParams(service, conn.id);
    await _demoPrepareExecuteClose(service, conn.id);
    await _demoTransactionRollbackAndRelease(service, conn.id);
    await _demoBulkInsert(service, conn.id);
    await _demoPoolApi(service, dsn);
  } finally {
    final disc = await service.disconnect(conn.id);
    disc.fold(
      (_) => AppLogger.info('Disconnected'),
      (e) => AppLogger.warning('Disconnect failed: $e'),
    );
  }
}

Future<void> _setupTable(OdbcService service, String connectionId) async {
  const sql = '''
    IF OBJECT_ID('service_api_coverage_table', 'U') IS NOT NULL
      DROP TABLE service_api_coverage_table;

    CREATE TABLE service_api_coverage_table (
      id INT NOT NULL PRIMARY KEY,
      name NVARCHAR(100) NOT NULL
    )
  ''';

  final result = await service.executeQuery(sql, connectionId: connectionId);
  result.fold(
    (_) => AppLogger.info('Table ready: service_api_coverage_table'),
    (e) => AppLogger.warning('Table setup failed: $e'),
  );
}

Future<void> _demoExecuteQueryParams(
  OdbcService service,
  String connectionId,
) async {
  final result = await service.executeQueryParams(
    connectionId,
    'SELECT ? AS number_value, ? AS text_value',
    [42, 'params-ok'],
  );

  result.fold(
    (r) => AppLogger.info('executeQueryParams rows=${r.rowCount}'),
    (e) => AppLogger.warning('executeQueryParams failed: $e'),
  );
}

Future<void> _demoPrepareExecuteClose(
  OdbcService service,
  String connectionId,
) async {
  final stmtResult = await service.prepare(
    connectionId,
    'INSERT INTO service_api_coverage_table (id, name) VALUES (?, ?)',
  );
  final stmtId = stmtResult.getOrNull();
  if (stmtId == null) {
    stmtResult.fold((_) {}, (e) => AppLogger.warning('prepare failed: $e'));
    return;
  }

  final exec = await service.executePrepared(
    connectionId,
    stmtId,
    [9001, 'prepared-row'],
    null,
  );
  exec.fold(
    (r) => AppLogger.info('executePrepared rows=${r.rowCount}'),
    (e) => AppLogger.warning('executePrepared failed: $e'),
  );

  final cancel = await service.cancelStatement(connectionId, stmtId);
  cancel.fold(
    (_) => AppLogger.info('cancelStatement OK'),
    (e) => AppLogger.info(
      'cancelStatement not available in current runtime (expected): $e',
    ),
  );

  final close = await service.closeStatement(connectionId, stmtId);
  close.fold(
    (_) => AppLogger.info('closeStatement OK'),
    (e) => AppLogger.warning('closeStatement failed: $e'),
  );
}

Future<void> _demoTransactionRollbackAndRelease(
  OdbcService service,
  String connectionId,
) async {
  final txnResult = await service.beginTransaction(connectionId);
  final txnId = txnResult.getOrNull();
  if (txnId == null) {
    txnResult.fold(
      (_) {},
      (e) => AppLogger.warning('beginTransaction failed: $e'),
    );
    return;
  }

  final sp = await service.createSavepoint(connectionId, txnId, 'sp_release');
  if (sp.isError()) {
    sp.fold((_) {}, (e) => AppLogger.warning('createSavepoint failed: $e'));
    final rb = await service.rollbackTransaction(connectionId, txnId);
    rb.fold(
      (_) => AppLogger.info('rollbackTransaction OK'),
      (e) => AppLogger.warning('rollbackTransaction failed: $e'),
    );
    return;
  }

  final rel = await service.releaseSavepoint(connectionId, txnId, 'sp_release');
  rel.fold(
    (_) => AppLogger.info('releaseSavepoint OK'),
    (e) => AppLogger.warning('releaseSavepoint failed: $e'),
  );

  final rb = await service.rollbackTransaction(connectionId, txnId);
  rb.fold(
    (_) => AppLogger.info('rollbackTransaction OK'),
    (e) => AppLogger.warning('rollbackTransaction failed: $e'),
  );
}

Future<void> _demoBulkInsert(
  OdbcService service,
  String connectionId,
) async {
  final builder = BulkInsertBuilder()
      .table('service_api_coverage_table')
      .addColumn('id', BulkColumnType.i32)
      .addColumn('name', BulkColumnType.text, maxLen: 100)
      .addRow([1001, 'bulk-one'])
      .addRow([1002, 'bulk-two']);

  final payload = builder.build();
  final result = await service.bulkInsert(
    connectionId,
    builder.tableName,
    builder.columnNames,
    payload,
    builder.rowCount,
  );

  result.fold(
    (rows) => AppLogger.info('bulkInsert rows=$rows'),
    (e) => AppLogger.warning('bulkInsert failed: $e'),
  );
}

Future<void> _demoPoolApi(OdbcService service, String dsn) async {
  final poolResult = await service.poolCreate(dsn, 3);
  final poolId = poolResult.getOrNull();
  if (poolId == null) {
    poolResult.fold((_) {}, (e) => AppLogger.warning('poolCreate failed: $e'));
    return;
  }

  final health = await service.poolHealthCheck(poolId);
  health.fold(
    (ok) => AppLogger.info('poolHealthCheck healthy=$ok'),
    (e) => AppLogger.warning('poolHealthCheck failed: $e'),
  );

  final state = await service.poolGetState(poolId);
  state.fold(
    (s) => AppLogger.info('poolGetState size=${s.size} idle=${s.idle}'),
    (e) => AppLogger.warning('poolGetState failed: $e'),
  );

  final pooledConnResult = await service.poolGetConnection(poolId);
  final pooledConn = pooledConnResult.getOrNull();
  if (pooledConn != null) {
    final pooledQuery = await service.executeQuery(
      'SELECT 1 AS pooled_ok',
      connectionId: pooledConn.id,
    );
    pooledQuery.fold(
      (r) => AppLogger.info('Pooled query rows=${r.rowCount}'),
      (e) => AppLogger.warning('Pooled query failed: $e'),
    );

    final builder = BulkInsertBuilder()
        .table('service_api_coverage_table')
        .addColumn('id', BulkColumnType.i32)
        .addColumn('name', BulkColumnType.text, maxLen: 100)
        .addRow([2001, 'parallel-one'])
        .addRow([2002, 'parallel-two']);

    final parallel = await service.bulkInsertParallel(
      poolId,
      builder.tableName,
      builder.columnNames,
      builder.build(),
      builder.rowCount,
      parallelism: 2,
    );
    parallel.fold(
      (rows) => AppLogger.info('bulkInsertParallel rows=$rows'),
      (e) => AppLogger.warning('bulkInsertParallel failed: $e'),
    );

    final release = await service.poolReleaseConnection(pooledConn.id);
    release.fold(
      (_) => AppLogger.info('poolReleaseConnection OK'),
      (e) => AppLogger.warning('poolReleaseConnection failed: $e'),
    );
  } else {
    pooledConnResult.fold(
      (_) {},
      (e) => AppLogger.warning('poolGetConnection failed: $e'),
    );
  }

  final close = await service.poolClose(poolId);
  close.fold(
    (_) => AppLogger.info('poolClose OK'),
    (e) => AppLogger.warning('poolClose failed: $e'),
  );
}
