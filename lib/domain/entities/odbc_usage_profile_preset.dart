import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';

/// Default stream FFI chunk size (64 KiB) for non-server profiles.
const int defaultRecommendedStreamChunkSizeBytes = 64 * 1024;

/// Larger stream FFI chunk (1 MiB) for server / high-throughput profiles.
const int serverRecommendedStreamChunkSizeBytes = 1024 * 1024;

final class OdbcUsageProfilePreset {
  const OdbcUsageProfilePreset({
    required this.useAsync,
    required this.workerCount,
    required this.maxPendingRequests,
    required this.usesWaitForSlotBackpressure,
    required this.backpressureTimeout,
    required this.connectionTimeout,
    required this.loginTimeout,
    required this.queryTimeout,
    required this.autoReconnectOnConnectionLost,
    required this.maxReconnectAttempts,
    required this.reconnectBackoff,
    required this.poolIdleTimeout,
    required this.poolMaxLifetime,
    required this.poolConnectionTimeout,
    required this.recommendedPoolMaxSize,
    required this.recommendedResultEncoding,
    this.recommendedLazyStrings = false,
    this.recommendedStreamChunkSizeBytes =
        defaultRecommendedStreamChunkSizeBytes,
    this.recommendedInitialResultBufferBytes,
  });

  final bool useAsync;
  final int workerCount;
  final int? maxPendingRequests;
  final bool usesWaitForSlotBackpressure;
  final Duration? backpressureTimeout;
  final Duration? connectionTimeout;
  final Duration? loginTimeout;
  final Duration? queryTimeout;
  final bool autoReconnectOnConnectionLost;
  final int? maxReconnectAttempts;
  final Duration? reconnectBackoff;
  final Duration? poolIdleTimeout;
  final Duration? poolMaxLifetime;
  final Duration? poolConnectionTimeout;
  final int recommendedPoolMaxSize;

  /// Suggested [ResultEncoding] for analytics-style SELECT workloads on this
  /// profile. Server presets default to [ResultEncoding.columnar]; other
  /// presets keep [ResultEncoding.rowMajor] for compatibility. Applied to
  /// columnar-typed APIs only — QueryResult APIs always use row-major wire.
  final ResultEncoding recommendedResultEncoding;

  /// When true, `ConnectionOptions.fromUsageProfile` enables `lazyStrings`.
  /// Server presets opt in for text-heavy analytics; other presets stay false.
  final bool recommendedLazyStrings;

  /// Suggested `streamQuery*(chunkSize:)` value for large scans on this
  /// profile. Does not change public API signature defaults (still 64 KiB).
  final int recommendedStreamChunkSizeBytes;

  /// Suggested `ConnectionOptions.initialResultBufferBytes` for this profile.
  /// Server presets use 1 MiB; others leave null (package default 64 KiB).
  final int? recommendedInitialResultBufferBytes;
}

OdbcUsageProfilePreset resolveOdbcUsageProfilePreset(
  OdbcUsageProfile profile,
) {
  switch (profile) {
    case OdbcUsageProfile.balanced:
      return const OdbcUsageProfilePreset(
        useAsync: true,
        workerCount: 2,
        maxPendingRequests: 24,
        usesWaitForSlotBackpressure: true,
        backpressureTimeout: Duration(seconds: 30),
        connectionTimeout: null,
        loginTimeout: Duration(seconds: 30),
        queryTimeout: Duration(seconds: 120),
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 3,
        reconnectBackoff: Duration(seconds: 1),
        poolIdleTimeout: Duration(minutes: 5),
        poolMaxLifetime: Duration(minutes: 30),
        poolConnectionTimeout: Duration(seconds: 30),
        recommendedPoolMaxSize: 4,
        recommendedResultEncoding: ResultEncoding.rowMajor,
      );
    case OdbcUsageProfile.balancedFlutter:
      return const OdbcUsageProfilePreset(
        useAsync: true,
        workerCount: 1,
        maxPendingRequests: 16,
        usesWaitForSlotBackpressure: true,
        backpressureTimeout: Duration(seconds: 30),
        connectionTimeout: null,
        loginTimeout: Duration(seconds: 30),
        queryTimeout: Duration(seconds: 120),
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 3,
        reconnectBackoff: Duration(seconds: 1),
        poolIdleTimeout: Duration(minutes: 5),
        poolMaxLifetime: Duration(minutes: 30),
        poolConnectionTimeout: Duration(seconds: 30),
        recommendedPoolMaxSize: 4,
        recommendedResultEncoding: ResultEncoding.rowMajor,
      );
    case OdbcUsageProfile.balancedServer:
      return const OdbcUsageProfilePreset(
        useAsync: true,
        workerCount: 4,
        maxPendingRequests: 32,
        usesWaitForSlotBackpressure: true,
        backpressureTimeout: Duration(seconds: 60),
        connectionTimeout: null,
        loginTimeout: Duration(seconds: 30),
        queryTimeout: Duration(seconds: 120),
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 3,
        reconnectBackoff: Duration(seconds: 1),
        poolIdleTimeout: Duration(minutes: 5),
        poolMaxLifetime: Duration(minutes: 30),
        poolConnectionTimeout: Duration(seconds: 30),
        recommendedPoolMaxSize: 8,
        recommendedResultEncoding: ResultEncoding.columnar,
        recommendedLazyStrings: true,
        recommendedStreamChunkSizeBytes: serverRecommendedStreamChunkSizeBytes,
        recommendedInitialResultBufferBytes:
            serverRecommendedStreamChunkSizeBytes,
      );
    case OdbcUsageProfile.highThroughput:
      return const OdbcUsageProfilePreset(
        useAsync: true,
        workerCount: 6,
        maxPendingRequests: 48,
        usesWaitForSlotBackpressure: true,
        backpressureTimeout: Duration(seconds: 60),
        connectionTimeout: null,
        loginTimeout: Duration(seconds: 30),
        queryTimeout: Duration(seconds: 120),
        autoReconnectOnConnectionLost: true,
        maxReconnectAttempts: 3,
        reconnectBackoff: Duration(seconds: 1),
        poolIdleTimeout: Duration(minutes: 5),
        poolMaxLifetime: Duration(minutes: 30),
        poolConnectionTimeout: Duration(seconds: 30),
        recommendedPoolMaxSize: 12,
        recommendedResultEncoding: ResultEncoding.columnar,
        recommendedLazyStrings: true,
        recommendedStreamChunkSizeBytes: serverRecommendedStreamChunkSizeBytes,
        recommendedInitialResultBufferBytes:
            serverRecommendedStreamChunkSizeBytes,
      );
    case OdbcUsageProfile.legacy:
      return const OdbcUsageProfilePreset(
        useAsync: false,
        workerCount: 1,
        maxPendingRequests: null,
        usesWaitForSlotBackpressure: false,
        backpressureTimeout: null,
        connectionTimeout: null,
        loginTimeout: null,
        queryTimeout: null,
        autoReconnectOnConnectionLost: false,
        maxReconnectAttempts: null,
        reconnectBackoff: null,
        poolIdleTimeout: null,
        poolMaxLifetime: null,
        poolConnectionTimeout: null,
        recommendedPoolMaxSize: 4,
        recommendedResultEncoding: ResultEncoding.rowMajor,
      );
  }
}
