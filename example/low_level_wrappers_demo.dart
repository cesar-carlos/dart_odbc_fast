import 'dart:io';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn =
      Platform.environment['ODBC_TEST_DSN'] ?? Platform.environment['ODBC_DSN'];
  if (dsn == null || dsn.trim().isEmpty) {
    AppLogger.warning('Set ODBC_TEST_DSN (or ODBC_DSN) to run this demo.');
    return;
  }

  final native = NativeOdbcConnection();
  if (!native.initialize()) {
    AppLogger.severe('ODBC init failed: ${native.getError()}');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    final se = native.getStructuredError();
    AppLogger.severe(se?.message ?? native.getError());
    return;
  }

  try {
    _demoCatalogQuery(native, connId);
    _demoPreparedStatement(native, connId);
    _demoTransactionHandle(native, connId);
    _demoConnectionPool(native, dsn);
  } finally {
    native.disconnect(connId);
  }
}

void _demoCatalogQuery(NativeOdbcConnection native, int connId) {
  final catalog = native.catalogQuery(connId);
  final tables = catalog.tables();
  if (tables == null) {
    AppLogger.warning('catalog.tables failed: ${native.getError()}');
    return;
  }
  AppLogger.info('catalog.tables rowCount=${tables.rowCount}');
}

void _demoPreparedStatement(NativeOdbcConnection native, int connId) {
  final stmt = native.prepareStatement(
    connId,
    'SELECT ? AS id, ? AS msg',
  );
  if (stmt == null) {
    AppLogger.warning('prepareStatement failed: ${native.getError()}');
    return;
  }

  final bytes = stmt.execute(
    const [
      ParamValueInt32(123),
      ParamValueString('ok'),
    ],
  );
  stmt.close();

  if (bytes == null || bytes.isEmpty) {
    AppLogger.warning('executePrepared returned no data: ${native.getError()}');
    return;
  }

  final parsed = BinaryProtocolParser.parse(bytes);
  AppLogger.info('prepared rows=${parsed.rows}');
}

void _demoTransactionHandle(NativeOdbcConnection native, int connId) {
  final txn = native.beginTransactionHandle(
    connId,
    IsolationLevel.readCommitted.index,
  );
  if (txn == null) {
    AppLogger.warning('beginTransactionHandle failed: ${native.getError()}');
    return;
  }

  // In a real flow, you would execute statements here, then commit/rollback.
  final ok = txn.commit();
  AppLogger.info('txn.commit ok=$ok');
}

void _demoConnectionPool(NativeOdbcConnection native, String dsn) {
  final pool = native.createConnectionPool(dsn, 2);
  if (pool == null) {
    AppLogger.warning('createConnectionPool failed: ${native.getError()}');
    return;
  }

  final pooledConnId = pool.getConnection();
  if (pooledConnId == 0) {
    AppLogger.warning('pool.getConnection failed: ${native.getError()}');
    pool.close();
    return;
  }

  // Minimal “ping” using streaming (parsed output type) to keep the demo
  // simple.
  native
      .streamQueryBatched(pooledConnId, 'SELECT 1', fetchSize: 10)
      .take(1)
      .listen((_) {}, onError: (_) {});

  final released = pool.releaseConnection(pooledConnId);
  AppLogger.info('pool.releaseConnection ok=$released');

  final closed = pool.close();
  AppLogger.info('pool.close ok=$closed');
}
