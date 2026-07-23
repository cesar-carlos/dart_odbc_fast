import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:result_dart/result_dart.dart';

/// Query, prepared-statement, catalog, and bulk operations for the ODBC
/// repository.
abstract interface class IQueryRepository {
  Future<Result<QueryResult>> executeQuery(String connectionId, String sql);

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql);

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  });

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  );

  Future<Result<Unit>> closeStatement(String connectionId, int stmtId);

  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId);

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  });

  /// Typed columnar execute using columnar v2 wire and direct decode.
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  );

  Future<Result<QueryResult>> executeQueryParamBuffer(
    String connectionId,
    String sql,
    Uint8List? paramBuffer, {
    ResultEncoding? resultEncoding,
  });

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  );

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  );

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  });

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

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  );

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  });

  Future<Result<Unit>> clearStatementCache();

  Future<Result<Unit>> clearAllStatements();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics();
}
