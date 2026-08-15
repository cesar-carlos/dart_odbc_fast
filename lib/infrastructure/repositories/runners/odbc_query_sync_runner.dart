import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Synchronous and buffered single-result query execution.
class OdbcQuerySyncRunner {
  OdbcQuerySyncRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.parser,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final OdbcResultParser parser;

  /// Wired by the repository for streaming plumbing; not used by
  /// [executeQuery] (one-shot `execQuery` / params path).
  late StreamNativeQueryFn streamNativeQueryWithFallback;
  late StreamingFailureFn streamingFailureFromException;

  /// Executes [sql] via one-shot FFI (same path as empty-param
  /// [executeQueryParamValues]), not batched streaming.
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) =>
      executeQueryParamValues(
        connectionId,
        sql,
        const <ParamValue>[],
      );

  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = state.optionsFor(connectionId);

    Future<Result<QueryResult>> run() async {
      try {
        final maxBytes = opts?.maxResultBufferBytes;
        final initialBytes =
            opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : ffi.sync.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                resultEncoding: resultEncoding,
              );

        final qr = parser.parseBufferToQueryResult(
          buf,
          lazyStrings: opts?.lazyStrings ?? false,
        );
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
            fallbackMessage: 'Failed to execute parameterized query',
          );
        }
        return Success(qr);
      } on OdbcError catch (e) {
        return Failure<QueryResult, OdbcError>(e);
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

    final queryTimeout = state.optionsFor(connectionId)?.queryTimeout;
    Future<Result<QueryResult>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResult, OdbcError>(
            QueryError(message: odbcQueryTimedOutMessage),
          ),
        );
      }
      return run();
    }

    return connection.withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  Future<Result<TypedColumnarResult>> executeQueryColumnarParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<TypedColumnarResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = state.optionsFor(connectionId);

    Future<Result<TypedColumnarResult>> run() async {
      try {
        final maxBytes = opts?.maxResultBufferBytes;
        final initialBytes =
            opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                timeout: queryTimeout,
                resultEncoding: ResultEncoding.columnar,
              )
            : ffi.sync.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                resultEncoding: ResultEncoding.columnar,
              );

        final typed = parser.parseBufferToTypedColumnar(
          buf,
          lazyStrings: opts?.lazyStrings ?? false,
        );
        if (typed == null) {
          return await ffi.convertNativeErrorToFailure<TypedColumnarResult>(
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
            fallbackMessage: 'Failed to execute columnar query',
          );
        }
        return Success(typed);
      } on OdbcError catch (e) {
        return Failure<TypedColumnarResult, OdbcError>(e);
      } on Exception catch (e) {
        return ffi.convertNativeErrorToFailure<TypedColumnarResult>(
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

    final queryTimeout = opts?.queryTimeout;
    Future<Result<TypedColumnarResult>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<TypedColumnarResult, OdbcError>(
            QueryError(message: odbcQueryTimedOutMessage),
          ),
        );
      }
      return run();
    }

    return connection.withReconnect(
      connectionId,
      runWithTimeout,
      sqlForSlowQueryDetection: sql,
    );
  }

  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    try {
      final extract = NamedParameterParser.extract(sql);
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: extract.paramNames,
      );
      return await executeQueryParamValues(
        connectionId,
        extract.cleanedSql,
        paramValuesFromObjects(positional),
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
}
