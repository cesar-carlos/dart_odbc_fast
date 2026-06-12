import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Pool capability delegate for the ODBC service façade.
class OdbcPoolService {
  OdbcPoolService(this._repository);

  final IOdbcRepository _repository;

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      _repository.poolCreate(
        connectionString,
        maxSize,
        options: options,
      );

  Future<Result<Connection>> poolGetConnection(int poolId) =>
      _repository.poolGetConnection(poolId);

  Future<Result<void>> poolReleaseConnection(String connectionId) =>
      _repository.poolReleaseConnection(connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId) =>
      _repository.poolHealthCheck(poolId);

  Future<Result<PoolState>> poolGetState(int poolId) =>
      _repository.poolGetState(poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) =>
      _repository.poolGetStateDetailed(poolId);

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize) =>
      _repository.poolSetSize(poolId, newMaxSize);

  Future<Result<void>> poolClose(int poolId) => _repository.poolClose(poolId);
}
