/// Configuration for prepared statement cache.
///
/// Defines cache behavior including LRU eviction policy,
/// size limits, TTL, and thread safety.
///
/// Example:
/// ```dart
/// final config = PreparedStatementConfig(
///   maxCacheSize: 100,
///   ttl: Duration(minutes: 10),
/// );
/// ```
class PreparedStatementConfig {
  /// Creates a new [PreparedStatementConfig] instance.
  ///
  /// The [maxCacheSize] specifies maximum number of
  /// prepared statements per connection (default: 50).
  ///
  /// The [ttl] specifies time-to-live for cache entries
  /// (default: null = no expiration).
  ///
  /// The [enabled] allows disabling cache per-connection
  /// (default: true).
  const PreparedStatementConfig({
    this.maxCacheSize = 50,
    this.ttl,
    this.enabled = true,
  });

  /// Maximum number of prepared statements in cache per connection.
  final int maxCacheSize;

  /// Optional time-to-live for cache entries.
  ///
  /// When set, cached entries are automatically evicted
  /// after this duration.
  final Duration? ttl;

  /// Whether prepared statement caching is enabled.
  ///
  /// When false, all statements are prepared fresh
  /// (no caching).
  final bool enabled;
}
