import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart'
    show LazyString;
import 'package:odbc_fast/odbc_fast.dart' show LazyString;

/// Default maximum result buffer size in bytes (16 MB).
///
/// Used when [ConnectionOptions.maxResultBufferBytes] is null.
const int defaultMaxResultBufferBytes = 16 * 1024 * 1024;

/// Default maximum number of reconnect attempts when
/// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
const int defaultMaxReconnectAttempts = 3;

/// Default delay between reconnect attempts when
/// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
const Duration defaultReconnectBackoff = Duration(seconds: 1);

/// Default initial result buffer size in bytes (64 KB) when not set per
/// connection.
const int defaultInitialResultBufferBytes = 64 * 1024;

/// Resolves the effective stream FFI chunk size for a connection.
///
/// Explicit [chunkSize] wins; otherwise
/// [ConnectionOptions.streamChunkSizeBytes], then
/// [defaultRecommendedStreamChunkSizeBytes] (64 KiB).
int resolveStreamChunkSizeBytes({
  required int? chunkSize,
  ConnectionOptions? options,
}) =>
    chunkSize ??
    options?.streamChunkSizeBytes ??
    defaultRecommendedStreamChunkSizeBytes;

/// Options for connection establishment and statement execution.
///
/// Used when calling connect to configure timeouts. [loginTimeout] is passed
/// to the ODBC driver as the login/connection timeout.
/// [maxResultBufferBytes] caps the size of query result buffers for this
/// connection (default [defaultMaxResultBufferBytes] when null).
class ConnectionOptions {
  const ConnectionOptions({
    this.connectionTimeout,
    this.loginTimeout,
    this.queryTimeout,
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
    this.streamChunkSizeBytes,
    this.blockFetchBatchSize,
    this.sqlPointerCacheMaxSize,
    this.autoReconnectOnConnectionLost = false,
    this.maxReconnectAttempts,
    this.reconnectBackoff,
    this.slowQueryThreshold,
    this.lazyStrings = false,
  });

  /// Preset timeouts and reconnect policy for a usage profile.
  ///
  /// [OdbcUsageProfile.legacy] matches the historical all-null constructor.
  /// Other profiles enable login/query timeouts and transient reconnect.
  factory ConnectionOptions.fromUsageProfile(OdbcUsageProfile profile) {
    final preset = resolveOdbcUsageProfilePreset(profile);
    return ConnectionOptions(
      connectionTimeout: preset.connectionTimeout,
      loginTimeout: preset.loginTimeout,
      queryTimeout: preset.queryTimeout,
      initialResultBufferBytes: preset.recommendedInitialResultBufferBytes,
      streamChunkSizeBytes: preset.recommendedStreamChunkSizeBytes,
      autoReconnectOnConnectionLost: preset.autoReconnectOnConnectionLost,
      maxReconnectAttempts: preset.maxReconnectAttempts,
      reconnectBackoff: preset.reconnectBackoff,
      lazyStrings: preset.recommendedLazyStrings,
    );
  }

  /// Timeout for establishing the connection. When set, used as [loginTimeout]
  /// for the ODBC driver if [loginTimeout] is null.
  final Duration? connectionTimeout;

  /// Login timeout (ODBC SQL_ATTR_LOGIN_TIMEOUT). Takes precedence over
  /// [connectionTimeout] when both are set.
  final Duration? loginTimeout;

  /// Timeout for individual queries. Applied when using prepared statements
  /// with a timeout (e.g. `prepare` with `timeoutMs`).
  final Duration? queryTimeout;

  /// Maximum size in bytes for query result buffers on this connection.
  /// When null, [defaultMaxResultBufferBytes] is used.
  final int? maxResultBufferBytes;

  /// Initial size in bytes for query result buffer allocation. When null,
  /// repository runners use [defaultInitialResultBufferBytes] (64 KiB).
  /// Larger values (e.g. server presets at 1 MiB) reduce reallocation rounds
  /// for large result sets. Low-level FFI calls without an explicit seed still
  /// fall back to the native helper default (256 KiB).
  final int? initialResultBufferBytes;

  /// Preferred FFI stream fetch chunk size when `streamQuery*` callers omit
  /// `chunkSize`. Server presets use 1 MiB; otherwise runners fall back to
  /// 64 KiB ([defaultRecommendedStreamChunkSizeBytes]).
  final int? streamChunkSizeBytes;

  /// Preferred ODBC block-fetch row batch for buffered `executeQuery*` drains.
  ///
  /// When null, the native engine uses `ODBC_FAST_BLOCK_FETCH_BATCH` (default
  /// 256). Prepared statements already honor `StatementOptions.fetchSize`;
  /// prefer `streamQuery*` for large scans where Dart `fetchSize` is plumbed
  /// end-to-end. This field documents the connection-level intent and is
  /// forwarded when runners open prepared one-shots for buffered queries.
  final int? blockFetchBatchSize;

  /// Optional max entries for the process-local SQL UTF-8 pointer cache on the
  /// native engine constructed for this options set (default 256 when null).
  final int? sqlPointerCacheMaxSize;

  /// When true, the repository may attempt to reconnect and re-execute the
  /// operation on connection-lost errors. Default is false.
  final bool autoReconnectOnConnectionLost;

  /// Maximum number of reconnect attempts when
  /// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
  /// When null, [defaultMaxReconnectAttempts] is used.
  final int? maxReconnectAttempts;

  /// Delay between reconnect attempts.
  /// When null, [defaultReconnectBackoff] is used.
  final Duration? reconnectBackoff;

  /// Threshold above which a query's wall-clock duration triggers a
  /// `SlowQueryDetected` event on `IAdminService.events`. When `null`,
  /// the runtime falls back to `queryTimeout * 0.8` if a query timeout
  /// is set; otherwise no slow-query events are emitted.
  ///
  /// The threshold is observability-only — it does **not** cancel the
  /// query. Useful for dashboards / alerting on regressions.
  final Duration? slowQueryThreshold;

  /// When true, text cells in binary protocol decode paths are wrapped in
  /// [LazyString] instead of eagerly decoded. Opt-in for workloads that
  /// inspect only a subset of string columns.
  final bool lazyStrings;

  /// Effective login timeout in milliseconds:
  /// [loginTimeout] ?? [connectionTimeout], or 0 if neither is set.
  int get loginTimeoutMs {
    final d = loginTimeout ?? connectionTimeout;
    if (d == null) return 0;
    return d.inMilliseconds.clamp(0, 0x7FFFFFFF);
  }

  /// Effective max reconnect attempts when
  /// [ConnectionOptions.autoReconnectOnConnectionLost] is true.
  int get effectiveMaxReconnectAttempts =>
      maxReconnectAttempts ?? defaultMaxReconnectAttempts;

  /// Effective delay between reconnect attempts.
  Duration get effectiveReconnectBackoff =>
      reconnectBackoff ?? defaultReconnectBackoff;

  /// Effective slow-query threshold. Returns the explicit
  /// [slowQueryThreshold] when set, otherwise 80% of [queryTimeout]
  /// when a query timeout exists, otherwise `null` (no events).
  Duration? get effectiveSlowQueryThreshold {
    if (slowQueryThreshold != null) return slowQueryThreshold;
    final timeout = queryTimeout;
    if (timeout == null || timeout <= Duration.zero) return null;
    return Duration(microseconds: (timeout.inMicroseconds * 0.8).round());
  }

  /// Returns a human-readable validation message when options are invalid.
  ///
  /// Returns null when all configured values are valid.
  String? validate() {
    if (connectionTimeout != null && connectionTimeout! < Duration.zero) {
      return 'connectionTimeout cannot be negative';
    }
    if (loginTimeout != null && loginTimeout! < Duration.zero) {
      return 'loginTimeout cannot be negative';
    }
    if (queryTimeout != null && queryTimeout! < Duration.zero) {
      return 'queryTimeout cannot be negative';
    }
    if (maxResultBufferBytes != null && maxResultBufferBytes! <= 0) {
      return 'maxResultBufferBytes must be greater than zero';
    }
    if (initialResultBufferBytes != null && initialResultBufferBytes! <= 0) {
      return 'initialResultBufferBytes must be greater than zero';
    }
    if (streamChunkSizeBytes != null && streamChunkSizeBytes! <= 0) {
      return 'streamChunkSizeBytes must be greater than zero';
    }
    if (sqlPointerCacheMaxSize != null && sqlPointerCacheMaxSize! <= 0) {
      return 'sqlPointerCacheMaxSize must be greater than zero';
    }
    if (maxResultBufferBytes != null &&
        initialResultBufferBytes != null &&
        initialResultBufferBytes! > maxResultBufferBytes!) {
      return 'initialResultBufferBytes cannot be greater than '
          'maxResultBufferBytes';
    }
    if (maxReconnectAttempts != null && maxReconnectAttempts! < 0) {
      return 'maxReconnectAttempts cannot be negative';
    }
    if (reconnectBackoff != null && reconnectBackoff! < Duration.zero) {
      return 'reconnectBackoff cannot be negative';
    }
    return null;
  }
}
