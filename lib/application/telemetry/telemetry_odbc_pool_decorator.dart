import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_pool_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:result_dart/result_dart.dart';

/// Pool-shaped telemetry decorator implementing [IPoolService].
class TelemetryOdbcPoolDecorator implements IPoolService {
  /// Creates a pool telemetry decorator.
  TelemetryOdbcPoolDecorator(
    IPoolService pools,
    this._ops, [
    IOdbcService? aggregate,
  ])  : _pools = pools,
        _aggregate = aggregate ?? (pools is IOdbcService ? pools : null);

  final IPoolService _pools;
  final TelemetryOdbcOperations _ops;
  final IOdbcService? _aggregate;

  IOdbcService get _service => _aggregate ?? _pools as IOdbcService;

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _ops.inOperation(
        'ODBC.poolCreate',
        () => _pools.poolCreate(
          connectionString,
          maxSize,
          options: options,
        ),
      );

  @override
  Future<Result<Connection>> poolGetConnection(int poolId) => _ops.inOperation(
        'ODBC.poolGetConnection',
        () => _pools.poolGetConnection(poolId),
      );

  @override
  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      _ops.inOperation(
        'ODBC.poolReleaseConnection',
        () => _pools.poolReleaseConnection(connectionId),
      );

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) => _ops.inOperation(
        'ODBC.poolHealthCheck',
        () => _pools.poolHealthCheck(poolId),
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

  @override
  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      _ops.inOperation(
        'ODBC.poolSetSize',
        () => _pools.poolSetSize(poolId, newMaxSize),
      );

  @override
  Future<Result<void>> poolClose(int poolId) => _ops.inOperation(
        'ODBC.poolClose',
        () => _pools.poolClose(poolId),
      );
}
