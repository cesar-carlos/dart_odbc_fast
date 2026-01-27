import 'dart:async';

import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Non-Blocking Integration Tests', () {
    test('event loop ticks during long query when using async service',
        () async {
      final locator = ServiceLocator();
      locator.initialize(useAsync: true);

      final service = locator.asyncService;
      await service.initialize();

      final dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null) return;

      final connResult = await service.connect(dsn);
      await connResult.fold((conn) async {
        var eventLoopTicks = 0;
        final eventLoopTimer = Timer.periodic(
          const Duration(milliseconds: 16),
          (_) => eventLoopTicks++,
        );

        final stopwatch = Stopwatch()..start();
        await service.executeQuery(
          conn.id,
          "WAITFOR DELAY '00:00:03'; SELECT 1",
        );
        stopwatch.stop();

        eventLoopTimer.cancel();

        if (stopwatch.elapsedMilliseconds >= 2000) {
          expect(
            eventLoopTicks,
            greaterThan(150),
            reason: 'Event loop should tick normally during long query',
          );
        }
        await service.disconnect(conn.id);
      }, (_) => fail('Connection should succeed'));

      locator.shutdown();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
