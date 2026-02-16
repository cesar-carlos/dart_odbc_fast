// Async ServiceLocator demo (DB-dependent).
// Run: dart run example/async_service_locator_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize(useAsync: true);
  final service = locator.asyncService;

  try {
    final init = await service.initialize();
    if (init.isError()) {
      init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
      return;
    }

    final connResult = await service.connect(dsn);
    await connResult.fold((connection) async {
      final query = await service.executeQuery(
        'SELECT 1 AS id',
        connectionId: connection.id,
      );
      query.fold(
        (r) => AppLogger.info('Async query OK: rows=${r.rowCount}'),
        (e) => AppLogger.severe('Async query failed: $e'),
      );
      await service.disconnect(connection.id);
    }, (error) async {
      AppLogger.severe('Async connect failed: $error');
    });
  } finally {
    locator.shutdown();
  }
}
