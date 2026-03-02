// Audit logger demo (async typed wrapper).
// Run: dart run example/audit_example.dart

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
  final audit = locator.asyncAuditLogger;

  try {
    final init = await service.initialize();
    if (init.isError()) {
      init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
      return;
    }

    final enabled = await audit.enable();
    if (!enabled) {
      AppLogger.warning(
        'Audit API unavailable in current native library; '
        'skipping audit demo.',
      );
      return;
    }

    final connResult = await service.connect(dsn);
    await connResult.fold((connection) async {
      final query = await service.executeQuery(
        'SELECT 1 AS id',
        connectionId: connection.id,
      );
      query.fold(
        (r) => AppLogger.info('Query OK: rows=${r.rowCount}'),
        (e) => AppLogger.warning('Query failed: $e'),
      );

      final disconnect = await service.disconnect(connection.id);
      disconnect.fold(
        (_) => AppLogger.info('Disconnected'),
        (e) => AppLogger.warning('Disconnect error: $e'),
      );
    }, (error) async {
      AppLogger.severe('Connect failed: $error');
    });

    final status = await audit.getStatus();
    AppLogger.info(
      'Audit status: enabled=${status?.enabled} '
      'eventCount=${status?.eventCount}',
    );

    final events = await audit.getEvents(limit: 20);
    AppLogger.info('Audit events fetched: ${events.length}');
    for (final event in events.take(5)) {
      AppLogger.info(
        '[audit] type=${event.eventType} '
        'conn=${event.connectionId} query=${event.query}',
      );
    }

    await audit.clear();
  } finally {
    locator.shutdown();
  }
}
