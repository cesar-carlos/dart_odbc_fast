import 'package:meta/meta.dart';
import 'package:odbc_fast/core/di/async_backpressure_mode.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';

/// Effective profile configuration used by high-level Dart composition helpers.
///
/// This value object resolves one [OdbcUsageProfile] into the async worker
/// shape, connection defaults, pool defaults, and suggested pool size that the
/// package should expose to consumers.
@immutable
final class ResolvedOdbcUsageProfile {
  const ResolvedOdbcUsageProfile({
    required this.profile,
    required this.useAsync,
    required this.workerCount,
    required this.maxPendingRequests,
    required this.backpressureMode,
    required this.backpressureTimeout,
    required this.connectionOptions,
    required this.poolOptions,
    required this.recommendedPoolMaxSize,
  });

  factory ResolvedOdbcUsageProfile.fromUsageProfile(OdbcUsageProfile profile) {
    final preset = resolveOdbcUsageProfilePreset(profile);
    return ResolvedOdbcUsageProfile(
      profile: profile,
      useAsync: preset.useAsync,
      workerCount: preset.workerCount,
      maxPendingRequests: preset.maxPendingRequests,
      backpressureMode: preset.usesWaitForSlotBackpressure
          ? AsyncBackpressureMode.waitForSlot
          : AsyncBackpressureMode.failFast,
      backpressureTimeout: preset.backpressureTimeout,
      connectionOptions: ConnectionOptions.fromUsageProfile(profile),
      poolOptions: PoolOptions.fromUsageProfile(profile),
      recommendedPoolMaxSize: preset.recommendedPoolMaxSize,
    );
  }

  /// Preset selected by the caller.
  final OdbcUsageProfile profile;

  /// Whether async worker isolates should be used.
  final bool useAsync;

  /// Number of async worker isolates to create.
  final int workerCount;

  /// Optional queue cap for pending async requests.
  final int? maxPendingRequests;

  /// Backpressure policy when the pending-request cap is reached.
  final AsyncBackpressureMode backpressureMode;

  /// Optional time bound for `waitForSlot` backpressure.
  final Duration? backpressureTimeout;

  /// Connection defaults aligned with this profile.
  final ConnectionOptions connectionOptions;

  /// Pool defaults aligned with this profile.
  final PoolOptions poolOptions;

  /// Suggested `poolCreate(..., maxSize)` value for this profile.
  final int recommendedPoolMaxSize;
}
