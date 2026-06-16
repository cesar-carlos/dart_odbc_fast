import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:result_dart/result_dart.dart';

/// Connection-pool operations for the ODBC repository.
abstract interface class IPoolRepository {
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  });

  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  });

  Future<Result<Unit>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId);

  Future<Result<Unit>> poolSetSize(int poolId, int newMaxSize);

  Future<Result<Unit>> poolClose(int poolId);
}
