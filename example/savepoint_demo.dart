import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

/// Savepoint usage demo: create, rollback to, and release savepoints.
///
/// Requires a database that supports SAVEPOINT (e.g. PostgreSQL, MySQL).
/// SQL Server uses SAVE TRANSACTION / ROLLBACK TRANSACTION instead.
///
/// Prerequisites: Set ODBC_TEST_DSN in environment or .env.
/// Run: dart run example/savepoint_demo.dart
Future<void> main() async {
  print('=== ODBC Fast - Savepoint Demo ===\n');

  final dsn = Platform.environment['ODBC_TEST_DSN'];
  if (dsn == null || dsn.isEmpty) {
    print('Set ODBC_TEST_DSN to run this demo.');
    return;
  }

  final locator = ServiceLocator()..initialize();
  await locator.service.initialize();

  final service = locator.service;
  final connResult = await service.connect(dsn);
  if (connResult.fold((_) => false, (_) => true)) {
    print('Connect failed');
    return;
  }

  final conn = connResult.getOrElse((_) => throw StateError('no conn'));
  final beginResult = await service.beginTransaction(
    conn.id,
    IsolationLevel.readCommitted,
  );
  if (beginResult.fold((_) => false, (_) => true)) {
    print('Begin transaction failed');
    await service.disconnect(conn.id);
    return;
  }

  final txnId = beginResult.getOrElse((_) => throw StateError('no txn'));

  try {
    await service.executeQuery(
      conn.id,
      'CREATE TABLE IF NOT EXISTS sp_demo (id INT)',
    );
    await service.executeQuery(conn.id, 'INSERT INTO sp_demo VALUES (1)');

    final createSp =
        await service.createSavepoint(conn.id, txnId, 'before_second');
    if (createSp.fold((_) => false, (_) => true)) {
      print('Create savepoint failed (DB may not support SAVEPOINT)');
      await service.rollbackTransaction(conn.id, txnId);
      return;
    }

    await service.executeQuery(conn.id, 'INSERT INTO sp_demo VALUES (2)');
    await service.rollbackToSavepoint(conn.id, txnId, 'before_second');
    await service.executeQuery(conn.id, 'INSERT INTO sp_demo VALUES (3)');

    await service.commitTransaction(conn.id, txnId);

    final q = await service.executeQuery(
      conn.id,
      'SELECT id FROM sp_demo ORDER BY id',
    );
    q.fold(
      (result) {
        print('Rows after savepoint rollback: ${result.rows}');
      },
      (_) => print('Query failed'),
    );

    await service.executeQuery(conn.id, 'DROP TABLE IF EXISTS sp_demo');
  } finally {
    await service.disconnect(conn.id);
  }

  print('\nDemo completed.');
}
