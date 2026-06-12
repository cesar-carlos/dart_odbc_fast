import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show paramValuesFromObjects;
import 'package:result_dart/result_dart.dart';

/// Query-shaped telemetry delegate for the ODBC service decorator façade.
class TelemetryOdbcQueryDecorator {
  /// Creates a query telemetry delegate.
  TelemetryOdbcQueryDecorator(this._service, this._ops);

  final IOdbcService _service;
  final TelemetryOdbcOperations _ops;

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryParams',
        () => _service.executeQueryParamValues(
          connectionId,
          sql,
          paramValuesFromObjects(params),
          resultEncoding: resultEncoding,
        ),
      );

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryParamValues',
        () => _service.executeQueryParamValues(
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
      _ops.inOperation(
        'ODBC.executeQueryDirectedParams',
        () => _service.executeQueryDirectedParams(connectionId, sql, params),
      );

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      _ops.wrapStream(
        'ODBC.streamQuery',
        () => _service.streamQuery(connectionId, sql),
      );

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _ops.inOperation(
        'ODBC.prepare',
        () => _service.prepare(connectionId, sql, timeoutMs: timeoutMs),
      );

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _ops.inOperation(
        'ODBC.prepareNamed',
        () => _service.prepareNamed(connectionId, sql, timeoutMs: timeoutMs),
      );

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) =>
      _ops.inOperation(
        'ODBC.executePrepared',
        () => _service.executePreparedParamValues(
          connectionId,
          stmtId,
          params == null || params.isEmpty
              ? null
              : paramValuesFromObjects(params),
          options,
        ),
      );

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  ) =>
      _ops.inOperation(
        'ODBC.executePreparedParamValues',
        () => _service.executePreparedParamValues(
          connectionId,
          stmtId,
          params,
          options,
        ),
      );

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      _ops.inOperation(
        'ODBC.executePreparedNamed',
        () => _service.executePreparedNamed(
          connectionId,
          stmtId,
          namedParams,
          options,
        ),
      );

  Future<Result<void>> closeStatement(String connectionId, int stmtId) =>
      _ops.inOperation(
        'ODBC.closeStatement',
        () => _service.closeStatement(connectionId, stmtId),
      );

  Future<Result<void>> cancelStatement(String connectionId, int stmtId) =>
      _ops.inOperation(
        'ODBC.cancelStatement',
        () => _service.cancelStatement(connectionId, stmtId),
      );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryMulti',
        () => _service.executeQueryMulti(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryMultiFull',
        () => _service.executeQueryMultiFull(connectionId, sql),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryMultiParams',
        () => _service.executeQueryMultiParamValues(
          connectionId,
          sql,
          paramValuesFromObjects(params),
        ),
      );

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryMultiParamValues',
        () => _service.executeQueryMultiParamValues(connectionId, sql, params),
      );

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _ops.wrapStream(
        'ODBC.streamQueryMulti',
        () => _service.streamQueryMulti(connectionId, sql),
      );

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryNamed',
        () => _service.executeQueryNamed(connectionId, sql, namedParams),
      );

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _ops.wrapStream(
        'ODBC.streamQueryNamed',
        () => _service.streamQueryNamed(connectionId, sql, namedParams),
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnar(
    String connectionId,
    String sql, {
    List<dynamic>? params,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryColumnar',
        () => _service.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params: params == null ? null : paramValuesFromObjects(params),
        ),
      );

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryColumnarParamValues',
        () => _service.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params: params,
        ),
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) =>
      _ops.wrapStream(
        'ODBC.streamQueryColumnar',
        () => _service.streamQueryColumnar(connectionId, sql),
      );

  Future<Result<QueryResult>> catalogTables({
    required String connectionId,
    String catalog = '',
    String schema = '',
  }) =>
      _ops.inOperation(
        'ODBC.catalogTables',
        () => _service.catalogTables(
          connectionId: connectionId,
          catalog: catalog,
          schema: schema,
        ),
      );

  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) =>
      _ops.inOperation(
        'ODBC.catalogColumns',
        () => _service.catalogColumns(connectionId, table),
      );

  Future<Result<QueryResult>> catalogTypeInfo(String connectionId) =>
      _ops.inOperation(
        'ODBC.catalogTypeInfo',
        () => _service.catalogTypeInfo(connectionId),
      );

  Future<Result<QueryResult>> catalogPrimaryKeys(
    String connectionId,
    String table,
  ) =>
      _ops.inOperation(
        'ODBC.catalogPrimaryKeys',
        () => _service.catalogPrimaryKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogForeignKeys(
    String connectionId,
    String table,
  ) =>
      _ops.inOperation(
        'ODBC.catalogForeignKeys',
        () => _service.catalogForeignKeys(connectionId, table),
      );

  Future<Result<QueryResult>> catalogIndexes(
    String connectionId,
    String table,
  ) =>
      _ops.inOperation(
        'ODBC.catalogIndexes',
        () => _service.catalogIndexes(connectionId, table),
      );

  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) =>
      _ops.inOperation(
        'ODBC.bulkInsert',
        () => _service.bulkInsert(
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
      _ops.inOperation(
        'ODBC.bulkInsertParallel',
        () => _service.bulkInsertParallel(
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
    List<dynamic>? params,
    String? connectionId,
  }) =>
      _ops.inOperation(
        'ODBC.executeQuery',
        () async {
          final cid = connectionId;
          if (cid == null || cid.isEmpty) {
            return const Failure<QueryResult, OdbcError>(
              ConnectionError(
                message: 'No active connection. Call connect() first.',
              ),
            );
          }
          return _service.executeQueryParamValues(
            cid,
            sql,
            params == null || params.isEmpty
                ? const <ParamValue>[]
                : paramValuesFromObjects(params),
          );
        },
      );
}
