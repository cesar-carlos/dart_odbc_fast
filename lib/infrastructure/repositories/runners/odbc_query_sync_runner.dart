import 'dart:async';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
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

  late StreamNativeQueryFn streamNativeQueryWithFallback;
  late StreamingFailureFn streamingFailureFromException;

  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    final opts = state.optionsFor(connectionId);

    Future<Result<QueryResult>> run() async {
      try {
        final stream = streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: opts?.maxResultBufferBytes,
        );
        final queryTimeout = opts?.queryTimeout;
        if (queryTimeout != null && queryTimeout != Duration.zero) {
          return _collectBufferedStreamWithTimeout(
            stream: stream,
            queryTimeout: queryTimeout,
          );
        }
        return _collectBufferedStream(stream);
      } on Exception catch (e) {
        return streamingFailureFromException(e);
      }
    }

    return connection.withReconnect(
      connectionId,
      run,
      sqlForSlowQueryDetection: sql,
    );
  }

  Future<Result<QueryResult>> _collectBufferedStream(
    Stream<ParsedRowBuffer> stream,
  ) async {
    List<List<dynamic>>? firstRows;
    List<List<dynamic>>? multiRows;
    final columns = <String>[];

    await for (final chunk in stream) {
      if (columns.isEmpty && chunk.columnCount > 0) {
        columns.addAll(chunk.columnNames);
      }
      if (firstRows == null) {
        firstRows = chunk.rows;
      } else {
        (multiRows ??= List.of(firstRows)).addAll(chunk.rows);
      }
    }

    final rows = multiRows ?? firstRows ?? const <List<dynamic>>[];
    return Success(
      QueryResult(columns: columns, rows: rows, rowCount: rows.length),
    );
  }

  Future<Result<QueryResult>> _collectBufferedStreamWithTimeout({
    required Stream<ParsedRowBuffer> stream,
    required Duration queryTimeout,
  }) async {
    final completer = Completer<Result<QueryResult>>();
    StreamSubscription<ParsedRowBuffer>? subscription;
    Timer? timer;
    List<List<dynamic>>? firstRows;
    List<List<dynamic>>? multiRows;
    final columns = <String>[];

    void finish(Result<QueryResult> result) {
      timer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    subscription = stream.listen(
      (chunk) {
        if (columns.isEmpty && chunk.columnCount > 0) {
          columns.addAll(chunk.columnNames);
        }
        if (firstRows == null) {
          firstRows = chunk.rows;
        } else {
          (multiRows ??= List.of(firstRows!)).addAll(chunk.rows);
        }
      },
      onError: (Object error) async {
        await subscription?.cancel();
        finish(await streamingFailureFromException(error as Exception));
      },
      onDone: () {
        final rows = multiRows ?? firstRows ?? const <List<dynamic>>[];
        finish(
          Success(
            QueryResult(columns: columns, rows: rows, rowCount: rows.length),
          ),
        );
      },
      cancelOnError: true,
    );

    timer = Timer(queryTimeout, () {
      subscription?.cancel();
      finish(
        const Failure<QueryResult, OdbcError>(
          QueryError(message: odbcQueryTimedOutMessage),
        ),
      );
    });

    return completer.future;
  }

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
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : ffi.sync.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                resultEncoding: resultEncoding,
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
            fallbackMessage: 'Failed to execute parameterized query',
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
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
                timeout: queryTimeout,
                resultEncoding: ResultEncoding.columnar,
              )
            : ffi.sync.executeQueryParams(
                nativeId,
                sql,
                params,
                maxBufferBytes: maxBytes,
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
      return executeQueryParamValues(
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
