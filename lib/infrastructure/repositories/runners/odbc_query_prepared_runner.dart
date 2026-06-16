import 'package:odbc_fast/domain/entities/odbc_metrics.dart'
    show PreparedStatementMetrics;
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Prepared-statement lifecycle and execution.
class OdbcQueryPreparedRunner {
  OdbcQueryPreparedRunner({
    required this.ffi,
    required this.state,
    required this.parser,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcResultParser parser;

  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    try {
      final stmtId = ffi.isAsync
          ? await ffi.async.prepare(nativeId, sql, timeoutMs: timeoutMs)
          : ffi.sync.prepare(nativeId, sql, timeoutMs: timeoutMs);

      if (stmtId == 0) {
        return await ffi.convertNativeErrorToFailure<int>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to prepare statement',
        );
      }
      // TOCTOU guard: while prepare was running, a concurrent disconnect()
      // may have removed connectionId from state.connectionIds. If so, the
      // native
      // statement is now orphaned (the worker still has it). Close it
      // proactively to prevent a native handle leak and surface the race.
      if (!state.connectionIds.containsKey(connectionId)) {
        try {
          if (ffi.isAsync) {
            await ffi.async.closeStatement(stmtId);
          } else {
            ffi.sync.closeStatement(stmtId);
          }
        } on Exception {
          // Best effort: native handle is unreachable anyway after disconnect.
        }
        return const Failure<int, OdbcError>(
          ValidationError(
            message: 'Connection was closed during prepare; statement freed',
          ),
        );
      }
      state.statementConnectionByStmtId[stmtId] = connectionId;
      return Success(stmtId);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final prepared = await prepare(
        connectionId,
        extract.cleanedSql,
        timeoutMs: timeoutMs,
      );
      // Use pattern-match instead of getOrElse((_) => 0): the latter conflates
      // a real stmtId of 0 (impossible today) with failure, and would silently
      // mis-register named-param metadata if the contract changed.
      prepared.fold(
        (stmtId) => state.namedParamOrderByStmtId[stmtId] = extract.paramNames,
        (_) {},
      );
      return prepared;
    } on Exception catch (e) {
      return Failure<int, OdbcError>(QueryError(message: e.toString()));
    }
  }

  Future<Result<QueryResult>> executePreparedParamValues(
    String connectionId,
    int stmtId,
    List<ParamValue>? params,
    StatementOptions? options,
  ) async {
    final ownership = state.validateStatementOwnership<QueryResult>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'executePrepared',
    );
    if (ownership != null) return ownership;

    try {
      final pv = params == null || params.isEmpty ? null : params;
      final timeoutMs = options?.timeout?.inMilliseconds ?? 0;
      final fetchSizeVal = options?.fetchSize ?? 1000;
      final maxBuf = options?.maxBufferSize;
      final buf = ffi.isAsync
          ? await ffi.async.executePrepared(
              stmtId,
              pv,
              timeoutMs,
              fetchSizeVal,
              maxBufferBytes: maxBuf,
            )
          : ffi.sync.executePrepared(
              stmtId,
              pv,
              timeoutMs,
              fetchSizeVal,
              maxBufferBytes: maxBuf,
            );

      final qr = parser.parseBufferToQueryResult(buf);
      if (qr == null) {
        return await ffi.convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({
            required message,
            sqlState,
            nativeCode,
          }) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to execute prepared statement',
        );
      }
      return Success(qr);
    } on Exception catch (e) {
      return ffi.convertNativeErrorToFailure<QueryResult>(
        errorFactory: ({
          required message,
          sqlState,
          nativeCode,
        }) =>
            QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: e.toString(),
      );
    }
  }

  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    final paramOrder = state.namedParamOrderByStmtId[stmtId];
    if (paramOrder == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(
          message: 'Statement was not prepared with prepareNamed',
        ),
      );
    }

    try {
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: paramOrder,
      );
      return executePreparedParamValues(
        connectionId,
        stmtId,
        paramValuesFromObjects(positional),
        options,
      );
    } on ParameterMissingException catch (e) {
      return Failure<QueryResult, OdbcError>(
        ValidationError(message: e.message),
      );
    } on Exception catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) async {
    final ownership = state.validateStatementOwnership<Unit>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'closeStatement',
    );
    if (ownership != null) return ownership;

    // Dart-side metadata is dropped unconditionally — even on a failed
    // close the native handle is past usable. Mirrors the original
    // `finally` block before the helper migration.
    void clearMetadata() {
      state.namedParamOrderByStmtId.remove(stmtId);
      state.statementConnectionByStmtId.remove(stmtId);
    }

    try {
      return await ffi.runBoolFfiWithCleanup(
        sync: (n) => n.closeStatement(stmtId),
        async: (a) => a.closeStatement(stmtId),
        onSuccess: clearMetadata,
        errorFactory: odbcQueryErrorFactory,
        fallbackMessage: 'Failed to close statement',
      );
    } finally {
      clearMetadata();
    }
  }

  Future<Result<Unit>> cancelStatement(String connectionId, int stmtId) async {
    final ownership = state.validateStatementOwnership<Unit>(
      connectionId: connectionId,
      stmtId: stmtId,
      operationName: 'cancelStatement',
    );
    if (ownership != null) return ownership;

    try {
      final ok = ffi.isAsync
          ? await ffi.async.cancelStatement(stmtId)
          : ffi.sync.cancelStatement(stmtId);
      if (ok) return const Success(unit);

      final structuredError = ffi.isAsync
          ? await ffi.async.getStructuredError()
          : ffi.sync.getStructuredError();
      final errorMsg =
          ffi.isAsync ? await ffi.async.getError() : ffi.sync.getError();
      final message = (errorMsg.isNotEmpty && errorMsg != 'No error')
          ? errorMsg
          : (structuredError?.message.isNotEmpty ?? false)
              ? structuredError!.message
              : 'Failed to cancel statement';
      final sqlState = structuredError?.sqlStateString;
      final nativeCode = structuredError?.nativeCode;

      if (isUnsupportedCancellation(
        message: message,
        sqlState: sqlState,
        nativeCode: nativeCode,
      )) {
        return Failure<Unit, OdbcError>(
          UnsupportedFeatureError(
            message: '$message. $odbcCancelStatementPreferQueryTimeoutHint',
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
        );
      }

      if (message.contains('Invalid statement ID')) {
        return Failure<Unit, OdbcError>(
          ValidationError(message: message),
        );
      }

      return Failure<Unit, OdbcError>(
        QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(QueryError(message: e.toString()));
    }
  }

  Future<Result<Unit>> clearStatementCache() async {
    try {
      final cleared = ffi.isAsync
          ? await ffi.async.clearStatementCache()
          : ffi.sync.clearStatementCache();

      if (!cleared) {
        return await ffi.convertNativeErrorToFailure<Unit>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to clear statement cache',
        );
      }
      return const Success(unit);
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> clearAllStatements() async {
    final r = await ffi.runIntFfi(
      sync: (n) => n.clearAllStatements(),
      async: (a) => a.clearAllStatements(),
      isSuccess: (code) => code == 0,
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: 'Failed to clear all statements',
    );
    return r.fold(
      (_) {
        state.clearAllStatementMetadata();
        return const Success<Unit, OdbcError>(unit);
      },
      (e) => Failure<Unit, OdbcError>(e as OdbcError),
    );
  }

  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    try {
      final metrics = ffi.isAsync
          ? await ffi.async.getCacheMetrics()
          : ffi.sync.getCacheMetrics();

      if (metrics == null) {
        return await ffi.convertNativeErrorToFailure<PreparedStatementMetrics>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get statement metrics',
        );
      }
      return Success(
        PreparedStatementMetrics(
          cacheSize: metrics.cacheSize,
          cacheMaxSize: metrics.cacheMaxSize,
          cacheHits: metrics.cacheHits,
          cacheMisses: metrics.cacheMisses,
          totalPrepares: metrics.totalPrepares,
          totalExecutions: metrics.totalExecutions,
          memoryUsageBytes: metrics.memoryUsageBytes,
          avgExecutionsPerStmt: metrics.avgExecutionsPerStmt,
        ),
      );
    } on Exception catch (e) {
      return Failure<PreparedStatementMetrics, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }
}
