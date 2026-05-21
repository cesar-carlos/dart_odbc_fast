import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';

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
      );
  }
}
