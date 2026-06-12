import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';

/// Preset tuning for `ServiceLocator.initialize` and related helpers.
///
/// Use [OdbcUsageProfile.balanced] for a recommended opt-in mix of
/// responsiveness, throughput, and safety. [OdbcUsageProfile.legacy] preserves
/// the package default behavior (sync-only, single worker, no pool/connection
/// timeouts from presets). Use [OdbcUsageProfile.highThroughput] for heavier
/// server workloads with more worker isolates and a larger recommended pool
/// size. See `ConnectionOptions.fromUsageProfile`,
/// `PoolOptions.fromUsageProfile`, and
/// `ResolvedOdbcUsageProfile.recommendedResultEncoding`.
enum OdbcUsageProfile {
  /// Async, two workers, moderate backpressure; recommended general preset.
  balanced,

  /// Async, single worker; best when the app mostly uses one connection.
  balancedFlutter,

  /// Async, four workers; for services with native pools and concurrency.
  balancedServer,

  /// Async, six workers; for heavier server workloads with larger pools.
  highThroughput,

  /// Historical defaults: sync API, single worker, no preset timeouts/reconnect.
  legacy,
  ;

  /// Suggested `maxSize` for `poolCreate` when using this profile.
  int get recommendedPoolMaxSize =>
      resolveOdbcUsageProfilePreset(this).recommendedPoolMaxSize;
}
