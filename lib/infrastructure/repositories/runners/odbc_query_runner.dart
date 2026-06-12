import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart'
    show PreparedStatementMetrics;
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_multi_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_prepared_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_sync_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Thin façade delegating query operations to focused sub-runners.
class OdbcQueryRunner {
  OdbcQueryRunner({
    required OdbcFfiDispatch ffi,
    required OdbcRepositoryState state,
    required OdbcConnectionRunner connection,
    required OdbcResultParser parser,
  })  : _sync = OdbcQuerySyncRunner(
          ffi: ffi,
          state: state,
          connection: connection,
          parser: parser,
        ),
        _multi = OdbcQueryMultiRunner(
          ffi: ffi,
          state: state,
          connection: connection,
          parser: parser,
        ),
        _prepared = OdbcQueryPreparedRunner(
          ffi: ffi,
          state: state,
          parser: parser,
        );

  final OdbcQuerySyncRunner _sync;
  final OdbcQueryMultiRunner _multi;
  final OdbcQueryPreparedRunner _prepared;

  set streamNativeQueryWithFallback(StreamNativeQueryFn fn) {
    _sync.streamNativeQueryWithFallback = fn;
  }

  StreamNativeQueryFn get streamNativeQueryWithFallback =>
      _sync.streamNativeQueryWithFallback;

  set streamingFailureFromException(StreamingFailureFn fn) {
    _sync.streamingFailureFromException = fn;
  }

  StreamingFailureFn get streamingFailureFromException =>
      _sync.streamingFailureFromException;

  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) =>
      _sync.executeQuery(connectionId, sql);

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _sync.executeQueryParams(
        connectionId,
        sql,
        params,
        resultEncoding: resultEncoding,
      );

  Future<Result<QueryResult>> executeQueryParamBuffer(
    String connectionId,
    String sql,
    Uint8List? paramBuffer, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) =>
      _multi.executeQueryParamBuffer(
        connectionId,
        sql,
        paramBuffer,
        resultEncoding: resultEncoding,
      );

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      _multi.executeQueryDirectedParams(connectionId, sql, params);

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _sync.executeQueryNamed(connectionId, sql, namedParams);

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) =>
      _multi.executeQueryMulti(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) =>
      _multi.executeQueryMultiFull(connectionId, sql);

  Future<Result<QueryResultMulti>> executeQueryMultiParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) =>
      _multi.executeQueryMultiParams(connectionId, sql, params);

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _prepared.prepare(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) =>
      _prepared.prepareNamed(connectionId, sql, timeoutMs: timeoutMs);

  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId, [
    List<dynamic>? params,
    StatementOptions? options,
  ]) =>
      _prepared.executePrepared(connectionId, stmtId, params, options);

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) =>
      _prepared.executePreparedNamed(
        connectionId,
        stmtId,
        namedParams,
        options,
      );

  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) =>
      _prepared.closeStatement(connectionId, stmtId);

  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId) =>
      _prepared.cancelStatement(connectionId, stmtId);

  Future<Result<Unit>> clearStatementCache() => _prepared.clearStatementCache();

  Future<Result<Unit>> clearAllStatements() => _prepared.clearAllStatements();

  Future<Result<PreparedStatementMetrics>> getPreparedStatementsMetrics() =>
      _prepared.getPreparedStatementsMetrics();
}
