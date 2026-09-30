import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/repositories/i_query_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Query / catalog / bulk capability delegate for the ODBC service façade.
class OdbcQueryService {
  OdbcQueryService(this._repository);

  final IQueryRepository _repository;

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryParamValues',
        () => _repository.executeQueryParamValues(
          connectionId,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryDirectedParams',
        () => _repository.executeQueryDirectedParams(
          connectionId,
          sql,
          params,
        ),
      );

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQuery',
        () => _repository.streamQuery(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepare',
        () => _repository.prepare(connectionId, sql, timeoutMs: timeoutMs),
      );

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      OdbcErrorBoundary.run(
        'prepareNamed',
        () => _repository.prepareNamed(
          connectionId,
          sql,
          timeoutMs: timeoutMs,
        ),
      );

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options, {
    ResultEncoding? resultEncoding,
  }) =>
      OdbcErrorBoundary.run(
        'executePreparedParamValues',
        () => _repository.executePreparedParamValues(
          connectionId,
          stmtId,
          params,
          options,
          resultEncoding: resultEncoding,
        ),
      );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      OdbcErrorBoundary.run(
        'executePreparedNamed',
        () => _repository.executePreparedNamed(
          connectionId,
          stmtId,
          namedParams,
          options,
        ),
      );

  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'closeStatement',
        () => _repository.closeStatement(connectionId, stmtId),
      );

  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      OdbcErrorBoundary.runVoid(
        'cancelStatement',
        () => _repository.cancelStatement(connectionId, stmtId),
      );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMulti',
        () => _repository.executeQueryMulti(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiFull',
        () => _repository.executeQueryMultiFull(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryMultiParamValues',
        () => _repository.executeQueryMultiParamValues(
          connectionId,
          sql,
          params,
        ),
      );

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMulti',
        () => _repository.streamQueryMulti(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiItem>> streamQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiParamValues',
        () => _repository.streamQueryMultiParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatchesParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatchesParamValues',
        () => _repository.streamQueryMultiBatchesParamValues(
          connectionId,
          sql,
          params,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatches(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryMultiBatches',
        () => _repository.streamQueryMultiBatches(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      OdbcErrorBoundary.run(
        'executeQueryNamed',
        () => _repository.executeQueryNamed(connectionId, sql, namedParams),
      );

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream(
        'streamQueryNamed',
        () => _repository.streamQueryNamed(
          connectionId,
          sql,
          namedParams,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      OdbcErrorBoundary.run(
        'executeQueryColumnarParamValues',
        () => _repository.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params ?? const <ParamValue>[],
        ),
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      OdbcErrorBoundary.stream('streamQueryColumnar', () async* {
        await for (final chunk in _repository.streamQueryColumnar(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        )) {
          yield chunk;
        }
      });

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      OdbcErrorBoundary.run(
        'catalogTables',
        () => _repository.catalogTables(
          connectionId,
          catalog: catalog,
          schema: schema,
        ),
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogColumns',
        () => _repository.catalogColumns(connectionId, table),
      );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      OdbcErrorBoundary.run(
        'catalogTypeInfo',
        () => _repository.catalogTypeInfo(connectionId),
      );

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogPrimaryKeys',
        () => _repository.catalogPrimaryKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogForeignKeys',
        () => _repository.catalogForeignKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      OdbcErrorBoundary.run(
        'catalogIndexes',
        () => _repository.catalogIndexes(connectionId, table),
      );

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      OdbcErrorBoundary.run(
        'bulkInsert',
        () => _repository.bulkInsert(
          connectionId,
          table,
          columns,
          dataBuffer,
          rowCount,
        ),
      );

  Future<Result<int>> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount, {
    int parallelism = 0,
  }) =>
      OdbcErrorBoundary.run(
        'bulkInsertParallel',
        () => _repository.bulkInsertParallel(
          poolId,
          table,
          columns,
          dataBuffer,
          rowCount,
          parallelism: parallelism,
        ),
      );

  Future<Result<QueryResult>> executeQuery(
    String sql, {
    String? connectionId,
  }) =>
      OdbcErrorBoundary.run('executeQuery', () async {
        if (connectionId == null || connectionId.isEmpty) {
          return const Failure(
            ConnectionError(
              message: 'No active connection. Call connect() first.',
            ),
          );
        }

        return executeQueryParamValues(
          connectionId,
          sql,
          const <ParamValue>[],
        );
      });
}
