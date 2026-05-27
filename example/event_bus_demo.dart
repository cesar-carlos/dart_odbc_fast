// Event bus demo: `IAdminService.events` broadcast stream.
//
// `IAdminService` exposes a `Stream<OdbcEvent>` that emits sealed
// connection-lifecycle events. Consumers can pattern-match exhaustively
// across:
//
//   * `ConnectionLost`         — `_withReconnect` saw a dropped connection.
//   * `AutoReconnectAttempted` — `_withReconnect` retried a request.
//   * `WorkerRecovered`        — async worker pool recovered after a crash.
//   * `PoolResize`             — `poolSetSize` changed pool capacity.
//   * `SlowQueryDetected`      — query crossed the configured threshold
//                                (`ConnectionOptions.slowQueryThreshold`
//                                or `queryTimeout * 0.8` fallback).
//
// Events are best-effort observability signals: emission never blocks the
// runtime path, the stream stays live even with no listeners, and the
// surface is sealed so a new variant is a deliberate additive change.
//
// Run: dart run example/event_bus_demo.dart
//
// Set `ODBC_EXAMPLE_DISABLE_DSN=1` to print the wiring without a DSN.

import 'dart:async';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    _describeEventsOffline();
    return;
  }

  // Async profile so the event bus has interesting traffic
  // (`WorkerRecovered` only fires on the async backend).
  final locator = ServiceLocator()
    ..initialize(profile: OdbcUsageProfile.balanced);
  final service = locator.service;

  // Subscribe BEFORE any operation so `PoolResize` / `SlowQueryDetected`
  // are not missed. The broadcast stream is multi-listener safe.
  final captured = <OdbcEvent>[];
  final subscription = service.events.listen(captured.add);

  try {
    final init = await service.initialize();
    if (init.isError()) {
      AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
      return;
    }

    // 1) Slow-query event: force the threshold to `Duration.zero` so any
    //    measurable wall-clock duration trips the emission. The runtime
    //    re-emits `SlowQueryDetected` on every executeQuery* call site
    //    threaded through `_withReconnect`.
    final connResult = await service.connect(
      dsn,
      options: const ConnectionOptions(
        slowQueryThreshold: Duration.zero,
        queryTimeout: Duration(seconds: 5),
      ),
    );
    if (connResult.isError()) {
      AppLogger.severe('connect failed: ${connResult.exceptionOrNull()}');
      return;
    }
    final conn = connResult.getOrThrow();
    try {
      await service.executeQuery('SELECT 1 AS v', connectionId: conn.id);
    } finally {
      await service.disconnect(conn.id);
    }

    // 2) PoolResize event: create a small pool, resize it, then close.
    final poolResult = await service.poolCreate(dsn, 2);
    if (poolResult.isSuccess()) {
      final poolId = poolResult.getOrThrow();
      await service.poolSetSize(poolId, 6);
      await service.poolClose(poolId);
    } else {
      AppLogger.warning(
        'poolCreate failed (skipping PoolResize demo): '
        '${poolResult.exceptionOrNull()}',
      );
    }
  } finally {
    // Drain pending microtasks so the broadcast controller delivers every
    // emitted event before the subscription is cancelled.
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    locator.shutdown();
  }

  _summariseEvents(captured);
}

void _summariseEvents(List<OdbcEvent> events) {
  AppLogger.info('--- Captured ${events.length} event(s) ---');
  for (final event in events) {
    final description = switch (event) {
      ConnectionLost(:final connectionId, :final reason) =>
        'ConnectionLost(connectionId=$connectionId, '
            'reason=${reason.runtimeType})',
      AutoReconnectAttempted(
        :final connectionId,
        :final attempt,
        :final maxAttempts,
      ) =>
        'AutoReconnectAttempted(connectionId=$connectionId, '
            'attempt=$attempt/$maxAttempts)',
      WorkerRecovered() => 'WorkerRecovered',
      PoolResize(:final poolId, :final oldSize, :final newSize) =>
        'PoolResize(poolId=$poolId, $oldSize -> $newSize)',
      SlowQueryDetected(:final connectionId, :final durationMs, :final sql) =>
        'SlowQueryDetected(connectionId=$connectionId, '
            'durationMs=$durationMs, sql=${_clipSql(sql)})',
    };
    AppLogger.info('  • $description');
  }
}

String _clipSql(String sql) =>
    sql.length > 60 ? '${sql.substring(0, 57)}...' : sql;

void _describeEventsOffline() {
  AppLogger.info(
    'Skipping DB-dependent example. '
    'IAdminService.events emits the following sealed variants:',
  );
  AppLogger.info('  - ConnectionLost(connectionId, reason)');
  AppLogger.info(
    '  - AutoReconnectAttempted(connectionId, attempt, maxAttempts)',
  );
  AppLogger.info('  - WorkerRecovered()');
  AppLogger.info('  - PoolResize(poolId, oldSize, newSize)');
  AppLogger.info('  - SlowQueryDetected(connectionId, sql, durationMs)');
  AppLogger.info(
    'Subscribe with `service.events.listen((e) { switch (e) { ... } })` '
    'and pattern-match exhaustively to stay forward-compatible.',
  );
}
