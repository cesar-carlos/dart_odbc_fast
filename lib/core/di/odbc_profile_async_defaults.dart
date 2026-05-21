import 'package:odbc_fast/core/di/async_backpressure_mode.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';

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
    final preset = resolveOdbcUsageProfilePreset(profile);
    return OdbcProfileAsyncDefaults(
      useAsync: preset.useAsync,
      workerCount: preset.workerCount,
      maxPendingRequests: preset.maxPendingRequests,
      backpressureMode: preset.usesWaitForSlotBackpressure
          ? AsyncBackpressureMode.waitForSlot
          : AsyncBackpressureMode.failFast,
      backpressureTimeout: preset.backpressureTimeout,
    );
  }

  final bool useAsync;
  final int workerCount;
  final int? maxPendingRequests;
  final AsyncBackpressureMode backpressureMode;
  final Duration? backpressureTimeout;
}
