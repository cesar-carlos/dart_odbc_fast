import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:result_dart/result_dart.dart';

/// Pool-shaped telemetry delegate for the ODBC service decorator façade.
class TelemetryOdbcPoolDecorator {
  /// Creates a pool telemetry delegate.
  TelemetryOdbcPoolDecorator(this._service, this._ops);

  final IOdbcService _service;
  final TelemetryOdbcOperations _ops;

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _ops.inOperation(
        'ODBC.poolCreate',
        () => _service.poolCreate(
          connectionString,
          maxSize,
          options: options,
        ),
      );

  Future<Result<Connection>> poolGetConnection(int poolId) => _ops.inOperation(
        'ODBC.poolGetConnection',
        () => _service.poolGetConnection(poolId),
      );

  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      _ops.inOperation(
        'ODBC.poolReleaseConnection',
        () => _service.poolReleaseConnection(connectionId),
      );

  Future<Result<bool>> poolHealthCheck(int poolId) => _ops.inOperation(
        'ODBC.poolHealthCheck',
        () => _service.poolHealthCheck(poolId),
      );

  Future<Result<PoolState>> poolGetState(int poolId) => _ops.inOperation(
        'ODBC.poolGetState',
        () => _service.poolGetState(poolId),
      );

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      _ops.inOperation(
        'ODBC.poolGetStateDetailed',
        () => _service.poolGetStateDetailed(poolId),
      );

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      _ops.inOperation(
        'ODBC.poolSetSize',
        () => _service.poolSetSize(poolId, newMaxSize),
      );

  Future<Result<void>> poolClose(int poolId) => _ops.inOperation(
        'ODBC.poolClose',
        () => _service.poolClose(poolId),
      );
}
