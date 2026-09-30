import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart'
    show serializeDirectedParams;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultParser;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Multi-result queries and raw parameter-buffer execution.
/// Runs multi-result query operations (`executeQueryMulti*`).
///
/// **Timeout note:** [ConnectionOptions.queryTimeout] wraps the isolate hop in
/// `Future.timeout` only. Buffered multi has no native async start/poll/cancel
/// path, so a timed-out Future does **not** cancel in-flight FFI work on the
/// worker. Prefer `streamQueryMulti` when cancellation matters.
class OdbcQueryMultiRunner {
  OdbcQueryMultiRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.parser,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final OdbcResultParser parser;

  Future<Result<QueryResult>> executeQueryParamBuffer(
    String connectionId,
    String sql,
    Uint8List? paramBuffer, {
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
      final nativeId = state.connectionIds[connectionId];
      if (nativeId == null) {
        return const Failure(
          ValidationError(message: 'Connection is unavailable'),
        );
      }
      try {
        final maxBytes = opts?.maxResultBufferBytes;
        final initialBytes =
            opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParamBuffer(
                nativeId,
                sql,
                paramBuffer,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : ffi.sync.executeQueryParamsRaw(
                nativeId,
                sql,
                paramBuffer,
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
      } on Exception catch (e, st) {
        return Failure(
          translateOdbcError(e, operation: 'executeQuery', stackTrace: st),
        );
      }
    }

    final queryTimeout = state.optionsFor(connectionId)?.queryTimeout;
    Future<Result<QueryResult>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResult, OdbcError>(
            QueryError(
              message: odbcQueryTimedOutMessage,
              details: OdbcErrorDetails(
                code: OdbcErrorCode.timeout,
                outcomeUnknown: true,
              ),
            ),
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

  Future<Result<QueryResult>> executeQueryDirectedParams(
    String connectionId,
    String sql,
    List<DirectedParam> params,
  ) =>
      executeQueryParamBuffer(
        connectionId,
        sql,
        serializeDirectedParams(params),
      );

  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    final full = await executeQueryMultiFull(connectionId, sql);
    return full.fold(
      (success) => Success(
        success.firstResultSetOrNull ??
            const QueryResult(columns: [], rows: [], rowCount: 0),
      ),
      (error) => Failure<QueryResult, OdbcError>(
        error is OdbcError ? error : QueryError(message: error.toString()),
      ),
    );
  }

  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResultMulti, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final initialBytes =
        opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;
    final lazyStrings = opts?.lazyStrings ?? false;

    Future<Result<QueryResultMulti>> run() async {
      final nativeId = state.connectionIds[connectionId];
      if (nativeId == null) {
        return const Failure(
          ValidationError(message: 'Connection is unavailable'),
        );
      }
      try {
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryMulti(
                nativeId,
                sql,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                fetchSize: opts?.blockFetchBatchSize ?? 0,
              )
            : ffi.sync.executeQueryMulti(
                nativeId,
                sql,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                fetchSize: opts?.blockFetchBatchSize ?? 0,
              );

        if (buf == null) {
          return await ffi.convertNativeErrorToFailure<QueryResultMulti>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'Failed to execute multi-result query',
            nativeConnectionId: nativeId,
          );
        }
        if (buf.isEmpty) {
          return const Success(
            QueryResultMulti(items: []),
          );
        }

        final items = MultiResultParser.parse(buf, lazyStrings: lazyStrings);
        return Success(parser.toQueryResultMulti(items));
      } on OdbcError catch (e) {
        return Failure(e);
      } on FormatException catch (e) {
        return Failure(MalformedPayloadError(message: e.message));
      } on Exception catch (e, st) {
        return Failure(
          translateOdbcError(e, operation: 'executeQuery', stackTrace: st),
        );
      }
    }

    final queryTimeout = state.optionsFor(connectionId)?.queryTimeout;
    Future<Result<QueryResultMulti>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResultMulti, OdbcError>(
            QueryError(
              message: odbcQueryTimedOutMessage,
              details: OdbcErrorDetails(
                code: OdbcErrorCode.timeout,
                outcomeUnknown: true,
              ),
            ),
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

  Future<Result<QueryResultMulti>> executeQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResultMulti, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final initialBytes =
        opts?.initialResultBufferBytes ?? defaultInitialResultBufferBytes;

    Future<Result<QueryResultMulti>> run() async {
      final nativeId = state.connectionIds[connectionId];
      if (nativeId == null) {
        return const Failure(
          ValidationError(message: 'Connection is unavailable'),
        );
      }
      try {
        final paramsBuffer = params.isEmpty ? null : serializeParams(params);
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryMultiParams(
                nativeId,
                sql,
                paramsBuffer,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                fetchSize: opts?.blockFetchBatchSize ?? 0,
              )
            : ffi.sync.executeQueryMultiParams(
                nativeId,
                sql,
                paramsBuffer,
                maxBufferBytes: maxBytes,
                initialBufferBytes: initialBytes,
                fetchSize: opts?.blockFetchBatchSize ?? 0,
              );

        if (buf == null) {
          return await ffi.convertNativeErrorToFailure<QueryResultMulti>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'Failed to execute multi-result query',
            nativeConnectionId: nativeId,
          );
        }
        if (buf.isEmpty) {
          return const Success(QueryResultMulti(items: []));
        }

        final items = MultiResultParser.parse(
          buf,
          lazyStrings: opts?.lazyStrings ?? false,
        );
        return Success(parser.toQueryResultMulti(items));
      } on OdbcError catch (e) {
        return Failure(e);
      } on FormatException catch (e) {
        return Failure(MalformedPayloadError(message: e.message));
      } on Exception catch (e, st) {
        return Failure(
          translateOdbcError(e, operation: 'executeQuery', stackTrace: st),
        );
      }
    }

    final queryTimeout = opts?.queryTimeout;
    Future<Result<QueryResultMulti>> runWithTimeout() {
      if (queryTimeout != null && queryTimeout != Duration.zero) {
        return run().timeout(
          queryTimeout,
          onTimeout: () => const Failure<QueryResultMulti, OdbcError>(
            QueryError(
              message: odbcQueryTimedOutMessage,
              details: OdbcErrorDetails(
                code: OdbcErrorCode.timeout,
                outcomeUnknown: true,
              ),
            ),
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
}
