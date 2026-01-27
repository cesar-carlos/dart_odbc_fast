import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn =
      Platform.environment['ODBC_TEST_DSN'] ?? Platform.environment['ODBC_DSN'];
  if (dsn == null || dsn.trim().isEmpty) {
    AppLogger.warning('Set ODBC_TEST_DSN (or ODBC_DSN) to run this demo.');
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.service;
  await service.initialize();

  final connResult = await service.connect(
    dsn,
    options: const ConnectionOptions(
      loginTimeout: Duration(seconds: 5),
      connectionTimeout: Duration(seconds: 5),
      queryTimeout: Duration(seconds: 2),
    ),
  );

  await connResult.fold((conn) async {
    AppLogger.info('Connected: ${conn.id}');

    final stmtIdResult = await service.prepare(
      conn.id,
      'SELECT 1',
      timeoutMs: const Duration(seconds: 2).inMilliseconds,
    );

    await stmtIdResult.fold((stmtId) async {
      AppLogger.info('Prepared statement: stmtId=$stmtId');

      final execResult = await service.executePrepared(conn.id, stmtId);
      execResult.fold(
        (qr) => AppLogger.info(
          'executePrepared: columns=${qr.columns} rowCount=${qr.rowCount}',
        ),
        (e) => AppLogger.warning('executePrepared failed: $e'),
      );

      await service.closeStatement(conn.id, stmtId);
    }, (e) async {
      AppLogger.severe('Prepare failed: $e');
    });

    await service.disconnect(conn.id);
  }, (e) async {
    AppLogger.severe('Connect failed: $e');
  });
}
