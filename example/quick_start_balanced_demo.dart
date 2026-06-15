// Minimal high-level demo: balanced defaults + recommended connection options.
// Run: dart run example/quick_start_balanced_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balanced);
  final service = locator.service;
  final tuning = locator.resolvedUsageProfile;
  AppLogger.info(
    'Profile=${tuning.profile.name}, async=${tuning.useAsync}, '
    'workers=${tuning.workerCount}, '
    'pendingCap=${tuning.maxPendingRequests ?? "unbounded"}',
  );

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final connResult = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );

  if (connResult.isError()) {
    AppLogger.severe('connect failed: ${connResult.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final conn = connResult.getOrElse(
    (_) => throw Exception('connect succeeded but value missing'),
  );

  try {
    final query = await service.executeQueryParamValues(
      conn.id,
      "SELECT 1 AS id, 'ok' AS msg",
      const <ParamValue>[],
    );
    query.fold(
      (r) => AppLogger.info('rows=${r.rowCount} columns=${r.columns}'),
      (e) => AppLogger.warning('query error: $e'),
    );

    final poolJson = locator.recommendedPoolOptions.toJson();
    final poolHint =
        'Optional pool: maxSize=${locator.recommendedPoolMaxSize}, '
        'options=${poolJson ?? "{}"}';
    AppLogger.info(poolHint);
  } finally {
    await service.disconnect(conn.id);
  }

  locator.shutdown();
}
