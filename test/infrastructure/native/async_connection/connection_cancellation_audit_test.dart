import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection cancellation', () {
    test('cancelStatement should return worker bool response', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerCancelSupport,
      );
      await async.initialize();
      final ok = await async.cancelStatement(42);
      expect(ok, isFalse);
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection audit', () {
    test('should enable/get/clear audit via worker messages', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAuditSupport,
      );
      await async.initialize();

      final enabled = await async.setAuditEnabled(enabled: true);
      final status = await async.getAuditStatusJson();
      final events = await async.getAuditEventsJson(limit: 10);
      final cleared = await async.clearAuditEvents();

      expect(enabled, isTrue);
      expect(status, contains('"enabled":true'));
      expect(events, startsWith('['));
      expect(cleared, isTrue);
      async.dispose();
    });
  });
}
