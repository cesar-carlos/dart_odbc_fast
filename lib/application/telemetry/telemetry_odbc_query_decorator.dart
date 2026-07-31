import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/param_value.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';

/// Query-shaped telemetry decorator implementing [IQueryService].
///
/// Extra methods beyond [IQueryService] (prepare, bulk insert, catalog) are
/// available when the wrapped service is an [IOdbcService].
class TelemetryOdbcQueryDecorator implements IQueryService {
  /// Creates a query telemetry decorator.
  ///
  /// Pass [aggregate] when wrapping a non-[IOdbcService] [IQueryService] but
  /// still needing aggregate-only forwards (for example from the aggregate
  /// telemetry decorator façade).
  TelemetryOdbcQueryDecorator(
    IQueryService queries,
    this._ops, [
    IOdbcService? aggregate,
  ])  : _queries = queries,
        _aggregate = aggregate ?? (queries is IOdbcService ? queries : null);

  final IQueryService _queries;
  final TelemetryOdbcOperations _ops;
  final IOdbcService? _aggregate;

  IOdbcService get _service => _aggregate ?? _queries as IOdbcService;

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryParamValues',
        () => _queries.executeQueryParamValues(
          connectionId,
          sql,
          params,
          resultEncoding: resultEncoding,
        ),
      );

  @override
  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryDirectedParams',
        () => _queries.executeQueryDirectedParams(connectionId, sql, params),
      );

  @override
  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _ops.wrapStream(
        'ODBC.streamQuery',
        () => _queries.streamQuery(
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

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryMultiParamValues',
        () => _service.executeQueryMultiParamValues(connectionId, sql, params),
      );

  @override
  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _ops.wrapStream(
        'ODBC.streamQueryMulti',
        () => _queries.streamQueryMulti(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _ops.inOperation(
        'ODBC.executeQueryNamed',
        () => _queries.executeQueryNamed(connectionId, sql, namedParams),
      );

  @override
  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _ops.wrapStream(
        'ODBC.streamQueryNamed',
        () => _queries.streamQueryNamed(
          connectionId,
          sql,
          namedParams,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
      );

  @override
  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql, {
    List<ParamValue>? params,
  }) =>
      _ops.inOperation(
        'ODBC.executeQueryColumnarParamValues',
        () => _queries.executeQueryColumnarParamValues(
          connectionId,
          sql,
          params: params,
        ),
      );

  @override
  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _ops.wrapStream(
        'ODBC.streamQueryColumnar',
        () => _queries.streamQueryColumnar(
          connectionId,
          sql,
          fetchSize: fetchSize,
          chunkSize: chunkSize,
        ),
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

  @override
  Future<Result<QueryResult>> executeQuery(
    String sql, {
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
          return _queries.executeQueryParamValues(
            cid,
            sql,
            const <ParamValue>[],
          );
        },
      );
}
