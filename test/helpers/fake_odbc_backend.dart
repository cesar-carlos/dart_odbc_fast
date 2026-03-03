/// Fake [OdbcConnectionBackend] for unit testing wrappers.
///
/// Allows configuring return values for each method to test
/// wrapper behavior without real ODBC.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Fake backend with configurable return values for testing.
class FakeOdbcConnectionBackend implements OdbcConnectionBackend {
  bool commitTransactionResult = true;
  bool rollbackTransactionResult = true;
  bool createSavepointResult = true;
  bool rollbackToSavepointResult = true;
  bool releaseSavepointResult = true;
  Uint8List? executePreparedResult;
  bool closeStatementResult = true;
  int clearAllStatementsResult = 0;
  PreparedStatementMetrics? getCacheMetricsResult;
  Uint8List? catalogTablesResult;
  Uint8List? catalogColumnsResult;
  Uint8List? catalogTypeInfoResult;
  int poolGetConnectionResult = 1;
  bool poolReleaseConnectionResult = true;
  bool poolHealthCheckResult = true;
  ({int size, int idle})? poolGetStateResult = (size: 5, idle: 3);
  bool poolCloseResult = true;
  bool poolSetSizeResult = true;
  int bulkInsertParallelResult = 10;

  @override
  bool commitTransaction(int txnId) => commitTransactionResult;

  @override
  bool rollbackTransaction(int txnId) => rollbackTransactionResult;

  @override
  bool createSavepoint(int txnId, String name) => createSavepointResult;

  @override
  bool rollbackToSavepoint(int txnId, String name) => rollbackToSavepointResult;

  @override
  bool releaseSavepoint(int txnId, String name) => releaseSavepointResult;

  @override
  Uint8List? executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) =>
      executePreparedResult;

  @override
  bool closeStatement(int stmtId) => closeStatementResult;

  @override
  int clearAllStatements() => clearAllStatementsResult;

  @override
  PreparedStatementMetrics? getCacheMetrics() => getCacheMetricsResult;

  @override
  Uint8List? catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) =>
      catalogTablesResult;

  @override
  Uint8List? catalogColumns(int connectionId, String table) =>
      catalogColumnsResult;

  @override
  Uint8List? catalogTypeInfo(int connectionId) => catalogTypeInfoResult;

  @override
  int poolGetConnection(int poolId) => poolGetConnectionResult;

  @override
  bool poolReleaseConnection(int connectionId) => poolReleaseConnectionResult;

  @override
  bool poolHealthCheck(int poolId) => poolHealthCheckResult;

  @override
  ({int size, int idle})? poolGetState(int poolId) => poolGetStateResult;

  @override
  bool poolClose(int poolId) => poolCloseResult;

  @override
  bool poolSetSize(int poolId, int newMaxSize) => poolSetSizeResult;

  @override
  int bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) =>
      bulkInsertParallelResult;
}
