// Savepoint usage demo with OdbcService transactions
// and ServiceLocator.
//
// Prerequisites: Set ODBC_TEST_DSN in environment or .env.
// Run: dart run example/savepoint_demo.dart

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/odbc_fast.dart';

void main() async {
  AppLogger.initialize();

  final dsn = _getExampleDsn();
  if (dsn == null || dsn.isEmpty) {
    AppLogger.warning(
      'ODBC_TEST_DSN not set. Set ODBC_TEST_DSN=... to run this demo.',
    );
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  print('=== ODBC Fast - Savepoint Demo ===\n');

  final initResult = await service.initialize();
  initResult.fold(
    (_) => print('OK: ODBC initialized'),
    (error) => print('ERR Init failed: $error'),
  );

  if (!initResult.isSuccess()) {
    return;
  }

  final connResult = await service.connect(dsn);
  final connection = connResult.getOrNull();
  if (connection == null) {
    connResult.fold(
      (_) {},
      (error) {
        final msg = error is OdbcError ? error.message : error.toString();
        print('ERR Connect failed: $msg');
        if (error is OdbcError) {
          if (error.sqlState != null) {
            print('  SQLSTATE: ${error.sqlState}');
          }
          if (error.nativeCode != null) {
            print('  Native code: ${error.nativeCode}');
          }
        }
      },
    );
    return;
  }

  print('OK: Connected: ${connection.id}');

  print('\nBeginning transaction...');
  final txnResult = await service.beginTransaction(connection.id);
  final txnId = txnResult.getOrNull();
  if (txnId == null) {
    txnResult.fold(
      (_) {},
      (error) => print(
        'ERR Begin transaction failed: '
        '${error is OdbcError ? error.message : error}',
      ),
    );
    return;
  }

  print('OK: Transaction begun: ID=$txnId');

  print('\nCreating savepoint "sp1"...');
  final spResult = await service.createSavepoint(
    connection.id,
    txnId,
    'sp1',
  );
  spResult.fold(
    (_) => print('OK: Savepoint created'),
    (error) => print(
      'ERR Create savepoint failed: '
      '${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nExecuting query...');
  final queryResult = await service.executeQuery(
    'SELECT 1',
    connectionId: connection.id,
  );
  queryResult.fold(
    (qr) => print('OK: Query returned ${qr.rowCount} rows'),
    (error) => print(
      'ERR Query failed: ${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nRolling back to savepoint "sp1"...');
  final rbResult = await service.rollbackToSavepoint(
    connection.id,
    txnId,
    'sp1',
  );
  rbResult.fold(
    (_) => print('OK: Rolled back to savepoint'),
    (error) => print(
      'ERR Rollback to savepoint failed: '
      '${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nExecuting query after rollback...');
  final qr2 = await service.executeQuery(
    'SELECT 1',
    connectionId: connection.id,
  );
  qr2.fold(
    (qr) => print('OK: Query returned ${qr.rowCount} rows'),
    (error) => print(
      'ERR Query failed: ${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nCommitting transaction...');
  final commitResult = await service.commitTransaction(connection.id, txnId);
  commitResult.fold(
    (_) => print('OK: Transaction committed'),
    (error) => print(
      'ERR Commit failed: ${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nDisconnecting...');
  final discResult = await service.disconnect(connection.id);
  discResult.fold(
    (_) => print('OK: Disconnected'),
    (error) => print(
      'ERR Disconnect error: ${error is OdbcError ? error.message : error}',
    ),
  );

  print('\nOK: Demo completed successfully!');
}

String? _getExampleDsn() {
  const path = '.env';
  final file = File(path);
  if (file.existsSync()) {
    final env = DotEnv(includePlatformEnvironment: true)..load([path]);
    final v = env['ODBC_TEST_DSN'];
    if (v != null && v.isNotEmpty) return v;
  }
  return Platform.environment['ODBC_TEST_DSN'] ??
      Platform.environment['ODBC_DSN'];
}
