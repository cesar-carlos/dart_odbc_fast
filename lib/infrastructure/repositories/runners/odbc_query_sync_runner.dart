import 'dart:async';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
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
        // Single-chunk fast path: when the entire result arrives in one chunk
        // (the common case for buffer-mode queries), reuse chunk.rows directly
        // and skip the addAll copy. Only allocate a growable accumulator when a
        // second chunk arrives.
        List<List<dynamic>>? firstRows;
        List<List<dynamic>>? multiRows;
        final columns = <String>[];

        await for (final chunk in streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: opts?.maxResultBufferBytes,
        )) {
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
      } on Exception catch (e) {
        return streamingFailureFromException(e);
      }
    }

    final queryTimeout = opts?.queryTimeout;
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

  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
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
        final pv = paramValuesFromObjects(params);
        final maxBytes = opts?.maxResultBufferBytes;
        final queryTimeout = opts?.queryTimeout;
        final buf = ffi.isAsync
            ? await ffi.async.executeQueryParams(
                nativeId,
                sql,
                pv,
                maxBufferBytes: maxBytes,
                timeout: queryTimeout,
                resultEncoding: resultEncoding,
              )
            : ffi.sync.executeQueryParams(
                nativeId,
                sql,
                pv,
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
      return executeQueryParams(connectionId, extract.cleanedSql, positional);
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
