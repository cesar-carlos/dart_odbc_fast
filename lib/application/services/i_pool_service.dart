import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:result_dart/result_dart.dart';

/// Pool-shaped operations subset of `IOdbcService`.
///
/// Lets infrastructure-level orchestrators (load balancers, lifecycle
/// managers, pool warmers) depend on the pool surface alone without
/// pulling in the query / transaction surface.
///
/// Mirrors the signatures of the corresponding `IOdbcService` members
/// exactly so existing call sites work both ways.
abstract interface class IPoolService {
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  });

  Future<Result<Connection>> poolGetConnection(int poolId);

  Future<Result<void>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<void>> poolSetSize(int poolId, int newMaxSize);

  Future<Result<void>> poolClose(int poolId);
}
