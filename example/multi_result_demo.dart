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

  final connResult = await service.connect(dsn);
  await connResult.fold((conn) async {
    AppLogger.info('Connected: ${conn.id}');

    final result = await service.executeQueryMulti(
      conn.id,
      'SELECT 1 AS a; SELECT 2 AS b;',
    );

    result.fold(
      (qr) => AppLogger.info(
        'First result set: columns=${qr.columns} rows=${qr.rows}',
      ),
      (e) => AppLogger.severe('executeQueryMulti failed: $e'),
    );

    await service.disconnect(conn.id);
  }, (e) async {
    AppLogger.severe('Connect failed: $e');
  });
}
