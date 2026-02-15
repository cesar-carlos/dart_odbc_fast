// Savepoint demo with OdbcService.
// Run: dart run example/savepoint_demo.dart

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

  try {
    final txnResult = await service.beginTransaction(conn.id);
    final txnId = txnResult.getOrNull();
    if (txnId == null) {
      txnResult.fold((_) {}, (e) => AppLogger.severe('Begin failed: $e'));
      return;
    }

    final sp = await service.createSavepoint(
      conn.id,
      txnId,
      'sp_before_query',
    );
    if (sp.isError()) {
      sp.fold((_) {}, (e) => AppLogger.severe('Savepoint failed: $e'));
      return;
    }

    final q1 = await service.executeQuery(
      'SELECT 1 AS before_rb',
      connectionId: conn.id,
    );
    q1.fold(
      (r) => AppLogger.info('Query before rollback rows=${r.rowCount}'),
      (e) => AppLogger.warning('Query before rollback failed: $e'),
    );

    final rb = await service.rollbackToSavepoint(
      conn.id,
      txnId,
      'sp_before_query',
    );
    rb.fold(
      (_) => AppLogger.info('Rolled back to savepoint'),
      (e) => AppLogger.severe('Rollback to savepoint failed: $e'),
    );

    final q2 = await service.executeQuery(
      'SELECT 1 AS after_rb',
      connectionId: conn.id,
    );
    q2.fold(
      (r) => AppLogger.info('Query after rollback rows=${r.rowCount}'),
      (e) => AppLogger.warning('Query after rollback failed: $e'),
    );

    final commit = await service.commitTransaction(conn.id, txnId);
    commit.fold(
      (_) => AppLogger.info('Transaction committed'),
      (e) => AppLogger.severe('Commit failed: $e'),
    );
  } finally {
    final disc = await service.disconnect(conn.id);
    disc.fold(
      (_) => AppLogger.info('Disconnected'),
      (e) => AppLogger.warning('Disconnect failed: $e'),
    );
  }
}
