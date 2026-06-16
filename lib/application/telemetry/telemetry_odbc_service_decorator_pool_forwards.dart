import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:result_dart/result_dart.dart';

/// Pool-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServicePoolForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  }) =>
      pool.poolCreate(
        connectionString,
        maxSize,
        options: options,
        connectionOptions: connectionOptions,
      );

  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  }) =>
      pool.poolGetConnection(poolId, options: options);

  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      pool.poolReleaseConnection(connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId) =>
      pool.poolHealthCheck(poolId);

  Future<Result<PoolState>> poolGetState(int poolId) =>
      pool.poolGetState(poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      pool.poolGetStateDetailed(poolId);

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      pool.poolSetSize(poolId, newMaxSize);

  Future<Result<void>> poolClose(int poolId) => pool.poolClose(poolId);
}
