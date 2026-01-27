import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Isolate Stress Tests', () {
    test(
      'should handle 100 concurrent operations without deadlock',
      () async {
        final async = AsyncNativeOdbcConnection();
        await async.initialize();

        final dsn = getTestEnv('ODBC_TEST_DSN');
        if (dsn == null) return;

        final futures = <Future<void>>[];
        for (var i = 0; i < 100; i++) {
          futures.add(() async {
            final connId = await async.connect(dsn);
            await async.executeQueryParams(connId, 'SELECT 1', []);
            await async.disconnect(connId);
          }());
        }

        await Future.wait(futures);
        async.dispose();
      },
      skip: 'Stress test - runs too long',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
