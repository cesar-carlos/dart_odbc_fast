import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:result_dart/result_dart.dart';

/// Pool-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServicePoolForwards on TelemetryOdbcServiceDecoratorBase {
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  }) =>
      OdbcErrorBoundary.run(
        'poolCreate',
        () => pool.poolCreate(
          connectionString,
          maxSize,
          options: options,
          connectionOptions: connectionOptions,
        ),
      );

  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  }) =>
      OdbcErrorBoundary.run(
        'poolGetConnection',
        () => pool.poolGetConnection(poolId, options: options),
      );

  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'poolReleaseConnection',
        () => pool.poolReleaseConnection(connectionId),
      );

  Future<Result<bool>> poolHealthCheck(int poolId) => OdbcErrorBoundary.run(
        'poolHealthCheck',
        () => pool.poolHealthCheck(poolId),
      );

  Future<Result<PoolState>> poolGetState(int poolId) =>
      OdbcErrorBoundary.run('poolGetState', () => pool.poolGetState(poolId));

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      OdbcErrorBoundary.run(
        'poolGetStateDetailed',
        () => pool.poolGetStateDetailed(poolId),
      );

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      OdbcErrorBoundary.runVoid(
        'poolSetSize',
        () => pool.poolSetSize(poolId, newMaxSize),
      );

  Future<Result<void>> poolClose(int poolId) =>
      OdbcErrorBoundary.runVoid('poolClose', () => pool.poolClose(poolId));
}
