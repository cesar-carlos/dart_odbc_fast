import 'package:result_dart/result_dart.dart';

import '../entities/connection.dart';
import '../entities/odbc_metrics.dart';
import '../entities/isolation_level.dart';
import '../entities/pool_state.dart';
import '../entities/query_result.dart';

abstract class IOdbcRepository {
  Future<Result<Unit>> initialize();

  Future<Result<Connection>> connect(String connectionString);

  Future<Result<Unit>> disconnect(String connectionId);

  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  );

  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  );

  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  );

  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
  ]);

  Future<Result<Unit>> closeStatement(String connectionId, int stmtId);

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  });

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId);

  Future<Result<int>> poolCreate(String connectionString, int maxSize);

  Future<Result<Connection>> poolGetConnection(int poolId);

  Future<Result<Unit>> poolReleaseConnection(String connectionId);

  Future<Result<bool>> poolHealthCheck(int poolId);

  Future<Result<PoolState>> poolGetState(int poolId);

  Future<Result<Unit>> poolClose(int poolId);

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  );

  Future<Result<OdbcMetrics>> getMetrics();

  bool isInitialized();
}
