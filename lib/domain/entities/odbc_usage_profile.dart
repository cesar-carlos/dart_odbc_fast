/// Preset tuning for `ServiceLocator.initialize` and related helpers.
///
/// Use [OdbcUsageProfile.balanced] for a good default mix of responsiveness,
/// throughput, and safety. Use [OdbcUsageProfile.legacy] to match pre-3.8
/// defaults (sync-only, single worker, no pool/connection timeouts from
/// presets). See `ConnectionOptions.fromUsageProfile` and
/// `PoolOptions.fromUsageProfile`.
enum OdbcUsageProfile {
  /// Async, two workers, moderate backpressure; universal default.
  balanced,

  /// Async, single worker; best when the app mostly uses one connection.
  balancedFlutter,

  /// Async, four workers; for services with native pools and concurrency.
  balancedServer,

  /// Historical defaults: sync API, single worker, no preset timeouts/reconnect.
  legacy,
  ;

  /// Suggested `maxSize` for `poolCreate` when using this profile.
  int get recommendedPoolMaxSize {
    switch (this) {
      case OdbcUsageProfile.balancedServer:
        return 8;
      case OdbcUsageProfile.balanced:
      case OdbcUsageProfile.balancedFlutter:
      case OdbcUsageProfile.legacy:
        return 4;
    }
  }
}
