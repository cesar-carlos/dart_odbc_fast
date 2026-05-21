import 'package:odbc_fast/core/di/odbc_profile_async_defaults.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcProfileAsyncDefaults', () {
    test('legacy matches historical sync defaults', () {
      final d =
          OdbcProfileAsyncDefaults.fromUsageProfile(OdbcUsageProfile.legacy);
      expect(d.useAsync, isFalse);
      expect(d.workerCount, 1);
      expect(d.maxPendingRequests, isNull);
      expect(d.backpressureMode, AsyncBackpressureMode.failFast);
      expect(d.backpressureTimeout, isNull);
    });

    test('balanced enables async with two workers', () {
      final d =
          OdbcProfileAsyncDefaults.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(d.useAsync, isTrue);
      expect(d.workerCount, 2);
      expect(d.maxPendingRequests, 24);
      expect(d.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(d.backpressureTimeout, const Duration(seconds: 30));
    });

    test('balancedFlutter uses single worker', () {
      final d = OdbcProfileAsyncDefaults.fromUsageProfile(
        OdbcUsageProfile.balancedFlutter,
      );
      expect(d.workerCount, 1);
      expect(d.maxPendingRequests, 16);
      expect(d.backpressureTimeout, const Duration(seconds: 30));
    });

    test('balancedServer uses four workers and longer slot wait', () {
      final d = OdbcProfileAsyncDefaults.fromUsageProfile(
        OdbcUsageProfile.balancedServer,
      );
      expect(d.workerCount, 4);
      expect(d.maxPendingRequests, 32);
      expect(d.backpressureTimeout, const Duration(seconds: 60));
    });

    test('highThroughput uses six workers and wider queue cap', () {
      final d = OdbcProfileAsyncDefaults.fromUsageProfile(
        OdbcUsageProfile.highThroughput,
      );
      expect(d.workerCount, 6);
      expect(d.maxPendingRequests, 48);
      expect(d.backpressureMode, AsyncBackpressureMode.waitForSlot);
      expect(d.backpressureTimeout, const Duration(seconds: 60));
    });
  });
}
