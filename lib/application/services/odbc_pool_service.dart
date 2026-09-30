import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/repositories/i_pool_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Pool capability delegate for the ODBC service façade.
class OdbcPoolService {
  OdbcPoolService(this._repository);

  final IPoolRepository _repository;

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  }) =>
      OdbcErrorBoundary.run(
        'poolCreate',
        () => _repository.poolCreate(
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
        () => _repository.poolGetConnection(poolId, options: options),
      );

  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      OdbcErrorBoundary.runVoid(
        'poolReleaseConnection',
        () => _repository.poolReleaseConnection(connectionId),
      );

  Future<Result<bool>> poolHealthCheck(int poolId) => OdbcErrorBoundary.run(
        'poolHealthCheck',
        () => _repository.poolHealthCheck(poolId),
      );

  Future<Result<PoolState>> poolGetState(int poolId) => OdbcErrorBoundary.run(
        'poolGetState',
        () => _repository.poolGetState(poolId),
      );

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      OdbcErrorBoundary.run(
        'poolGetStateDetailed',
        () => _repository.poolGetStateDetailed(poolId),
      );

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      OdbcErrorBoundary.runVoid(
        'poolSetSize',
        () => _repository.poolSetSize(poolId, newMaxSize),
      );

  Future<Result<void>> poolClose(int poolId) => OdbcErrorBoundary.runVoid(
        'poolClose',
        () => _repository.poolClose(poolId),
      );
}
