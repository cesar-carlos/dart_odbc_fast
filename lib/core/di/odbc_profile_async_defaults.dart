import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';

/// Resolved async worker/backpressure defaults for a usage profile.
final class OdbcProfileAsyncDefaults {
  const OdbcProfileAsyncDefaults({
    required this.useAsync,
    required this.workerCount,
    required this.backpressureMode,
    this.maxPendingRequests,
    this.backpressureTimeout,
  });

  factory OdbcProfileAsyncDefaults.fromUsageProfile(OdbcUsageProfile profile) {
    switch (profile) {
      case OdbcUsageProfile.legacy:
        return const OdbcProfileAsyncDefaults(
          useAsync: false,
          workerCount: 1,
          backpressureMode: AsyncBackpressureMode.failFast,
        );
      case OdbcUsageProfile.balanced:
        return const OdbcProfileAsyncDefaults(
          useAsync: true,
          workerCount: 2,
          maxPendingRequests: 24,
          backpressureMode: AsyncBackpressureMode.waitForSlot,
          backpressureTimeout: Duration(seconds: 30),
        );
      case OdbcUsageProfile.balancedFlutter:
        return const OdbcProfileAsyncDefaults(
          useAsync: true,
          workerCount: 1,
          maxPendingRequests: 16,
          backpressureMode: AsyncBackpressureMode.waitForSlot,
          backpressureTimeout: Duration(seconds: 30),
        );
      case OdbcUsageProfile.balancedServer:
        return const OdbcProfileAsyncDefaults(
          useAsync: true,
          workerCount: 4,
          maxPendingRequests: 32,
          backpressureMode: AsyncBackpressureMode.waitForSlot,
          backpressureTimeout: Duration(seconds: 60),
        );
    }
  }

  final bool useAsync;
  final int workerCount;
  final int? maxPendingRequests;
  final AsyncBackpressureMode backpressureMode;
  final Duration? backpressureTimeout;
}
