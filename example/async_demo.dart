import 'dart:async';
import 'dart:io';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/odbc_fast.dart';

/// Demonstration of TRUE non-blocking Async API.
///
/// This example proves non-blocking execution by:
/// 1. Running a long query while the event loop keeps ticking (UI responsive)
/// 2. Executing parallel queries (all complete without deadlock)
///
/// Prerequisites: Set ODBC_TEST_DSN in environment or .env.
/// Run: dart run example/async_demo.dart
Future<void> main() async {
  AppLogger.initialize();
  print('=== ODBC Fast - TRUE Non-Blocking Demo ===\n');

  final locator = ServiceLocator();
  locator.initialize(useAsync: true);

  final service = locator.asyncService;
  await service.initialize();

  print('Worker isolate spawned and initialized\n');

  await _demoNonBlockingQuery(service);
  await _demoParallelQueries(service);

  locator.shutdown();
  print('\nDemo completed.');
}

Future<void> _demoNonBlockingQuery(OdbcService service) async {
  print('Demo 1: Non-Blocking Query\n');

  final dsn = Platform.environment['ODBC_TEST_DSN'] ?? 'DSN=test';
  final connResult = await service.connect(dsn);

  return connResult.fold<Future<void>>((conn) async {
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) {
        ticks++;
        if (ticks % 60 == 0) stdout.write('.');
      },
    );

    print('Starting 5-second query...');
    print('Event loop ticking (each dot = 1 second):');

    final stopwatch = Stopwatch()..start();
    await service.executeQuery(
      conn.id,
      "WAITFOR DELAY '00:00:05'; SELECT 1",
    );
    stopwatch.stop();

    timer.cancel();
    print('\n');

    print('Query completed in ${stopwatch.elapsedMilliseconds}ms');
    print('Event loop ticked $ticks times (~${ticks ~/ 60} seconds)');
    print('UI was responsive throughout!\n');

    await service.disconnect(conn.id);
  }, (_) async {
    print('Connection failed (set ODBC_TEST_DSN for full demo)\n');
  });
}

Future<void> _demoParallelQueries(OdbcService service) async {
  print('Demo 2: Parallel Query Execution\n');

  final dsn = Platform.environment['ODBC_TEST_DSN'];
  if (dsn == null) {
    print('Skip: ODBC_TEST_DSN not set\n');
    return;
  }

  final connResult = await service.connect(dsn);
  return connResult.fold<Future<void>>((conn) async {
    final stopwatch = Stopwatch()..start();

    await Future.wait([
      service.executeQuery(conn.id, "WAITFOR DELAY '00:00:02'; SELECT 1"),
      service.executeQuery(conn.id, "WAITFOR DELAY '00:00:02'; SELECT 2"),
      service.executeQuery(conn.id, "WAITFOR DELAY '00:00:02'; SELECT 3"),
    ]);

    stopwatch.stop();

    print('3 queries (2s each) completed in ${stopwatch.elapsedMilliseconds}ms');
    print('Expected: ~2000ms+ (worker processes requests)\n');

    await service.disconnect(conn.id);
  }, (_) async {
    print('Connection failed\n');
  });
}
