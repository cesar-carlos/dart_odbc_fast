import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart'
    show MultiResultStreamDecoder;
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:result_dart/result_dart.dart';

/// Streaming query and async-poll operations.
class OdbcStreamRunner {
  OdbcStreamRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.parser,
    required this.query,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final OdbcResultParser parser;
  final OdbcQueryRunner query;

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResultMultiItem, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    // The streaming multi-result FFIs were added in v3.3.0. On older native
    // libraries, or when the async worker reports streaming unavailable, we
    // degrade gracefully to executeQueryMultiFull (single batch in memory) so
    // the API contract keeps working even without M8 binaries.
    final supportsStreaming = ffi.isAsync || ffi.sync.supportsStreamQueryMulti;
    if (!supportsStreaming) {
      final fallback = await query.executeQueryMultiFull(connectionId, sql);
      if (fallback.isError()) {
        final err = fallback.exceptionOrNull();
        yield Failure<QueryResultMultiItem, OdbcError>(
          err is OdbcError ? err : QueryError(message: err.toString()),
        );
        return;
      }
      final items = fallback.getOrNull()!.items;
      for (final item in items) {
        yield Success<QueryResultMultiItem, OdbcError>(item);
      }
      return;
    }

    var streamId = 0;
    try {
      streamId = ffi.isAsync
          ? await ffi.async.streamMultiStartBatched(nativeId, sql)
          : ffi.sync.streamMultiStartBatched(nativeId, sql) ?? 0;
      if (streamId == 0) {
        final fallback = await query.executeQueryMultiFull(connectionId, sql);
        if (fallback.isSuccess()) {
          for (final item in fallback.getOrNull()!.items) {
            yield Success<QueryResultMultiItem, OdbcError>(item);
          }
          return;
        }
        final structuredError = await ffi.getStructuredNativeError(
          nativeConnectionId: nativeId,
        );
        final nativeErr = structuredError?.message ??
            (ffi.isAsync ? await ffi.async.getError() : ffi.sync.getError());
        final fallbackErr = fallback.exceptionOrNull();
        final message = nativeErr.isNotEmpty && nativeErr != 'No error'
            ? nativeErr
            : (fallbackErr?.toString() ?? 'Streaming unavailable');
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(
            message: 'Failed to start streaming multi-result: $message',
            sqlState: structuredError?.sqlStateString,
            nativeCode: structuredError?.nativeCode,
          ),
        );
        return;
      }

      final decoder = MultiResultStreamDecoder();
      while (true) {
        final bool ok;
        final Uint8List? data;
        final bool hasMore;
        final String? errMsg;
        if (ffi.isAsync) {
          final fetched = await ffi.async.streamFetch(streamId);
          ok = fetched.success;
          data = fetched.data;
          hasMore = fetched.hasMore;
          errMsg = fetched.error;
        } else {
          final fetched = ffi.sync.streamFetch(streamId);
          ok = fetched.success;
          data = fetched.data;
          hasMore = fetched.hasMore;
          errMsg = ok ? null : ffi.sync.getError();
        }

        if (!ok) {
          yield Failure<QueryResultMultiItem, OdbcError>(
            QueryError(message: errMsg ?? 'Stream fetch failed'),
          );
          return;
        }
        if (data != null && data.isNotEmpty) {
          for (final item in decoder.feed(data)) {
            yield Success<QueryResultMultiItem, OdbcError>(
              parser.toQueryResultMultiItem(item),
            );
          }
        }
        if (!hasMore) {
          break;
        }
      }

      try {
        decoder.assertExhausted();
      } on FormatException catch (e) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          MalformedPayloadError(message: e.message),
        );
        return;
      }
    } on Exception catch (e) {
      yield Failure<QueryResultMultiItem, OdbcError>(
        QueryError(message: e.toString()),
      );
    } finally {
      if (streamId != 0) {
        if (ffi.isAsync) {
          await ffi.async.streamClose(streamId);
        } else {
          ffi.sync.streamClose(streamId);
        }
      }
    }
  }

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final queryTimeout = opts?.queryTimeout;

    Stream<Result<QueryResult>> createSource() async* {
      try {
        await for (final chunk in streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: maxBytes,
        )) {
          yield Success(parser.toQueryResult(chunk));
        }
      } on Exception catch (e) {
        yield await streamingFailureFromException(e);
      }
    }

    final source = createSource();

    if (queryTimeout != null && queryTimeout != Duration.zero) {
      await for (final item in source.timeout(
        queryTimeout,
        onTimeout: (sink) {
          sink
            ..add(
              const Failure<QueryResult, OdbcError>(
                QueryError(message: odbcQueryTimedOutMessage),
              ),
            )
            ..close();
        },
      )) {
        yield item;
      }
      return;
    }

    await for (final item in source) {
      yield item;
    }
  }

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async* {
    // The parameterized execute path does not support incremental batched
    // streaming at the FFI level. The full result is buffered and yielded as
    // a single chunk — consistent with the non-streaming execute contract but
    // wrapped in a Stream for API uniformity.
    yield await query.executeQueryNamed(connectionId, sql, namedParams);
  }

  Stream<ParsedRowBuffer> streamNativeQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
  }) async* {
    var emittedFromBatched = false;

    try {
      final batched = ffi.isAsync
          ? ffi.async.streamQueryBatched(
              nativeId,
              sql,
              maxBufferBytes: maxBufferBytes,
            )
          : ffi.sync.streamQueryBatched(nativeId, sql);

      await for (final chunk in batched) {
        emittedFromBatched = true;
        yield chunk;
      }
      return;
    } on Exception {
      if (emittedFromBatched) {
        rethrow;
      }
    }

    final fallback = ffi.isAsync
        ? ffi.async.streamQuery(nativeId, sql, maxBufferBytes: maxBufferBytes)
        : ffi.sync.streamQuery(nativeId, sql);

    await for (final chunk in fallback) {
      yield chunk;
    }
  }

  bool _isStreamingTimeoutException(
    Exception error,
    String normalizedMessage,
  ) {
    if (error is TimeoutException) {
      return true;
    }
    if (error is AsyncError && error.code == AsyncErrorCode.requestTimeout) {
      return true;
    }
    final lower = normalizedMessage.toLowerCase();
    return lower.contains('timeout') || lower.contains('timed out');
  }

  bool _isStreamingProtocolException(
    Exception error,
    String normalizedMessage,
  ) {
    if (error is FormatException) {
      return true;
    }
    final lower = normalizedMessage.toLowerCase();
    return lower.contains('protocol') ||
        lower.contains('leftover bytes') ||
        lower.contains('invalid magic') ||
        lower.contains('buffer too small');
  }

  bool _isStreamingInterruptionException(Exception error) {
    return error is AsyncError && error.code == AsyncErrorCode.workerTerminated;
  }

  Future<Failure<QueryResult, OdbcError>> streamingFailureFromException(
    Exception error,
  ) async {
    final normalizedMessage = error.toString();
    if (_isStreamingTimeoutException(error, normalizedMessage)) {
      return const Failure<QueryResult, OdbcError>(
        QueryError(message: odbcQueryTimedOutMessage),
      );
    }

    if (_isStreamingProtocolException(error, normalizedMessage)) {
      return Failure<QueryResult, OdbcError>(
        QueryError(
          message: '$odbcStreamProtocolErrorPrefix: $normalizedMessage',
        ),
      );
    }

    if (_isStreamingInterruptionException(error)) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: '$odbcStreamInterruptedPrefix: $normalizedMessage'),
      );
    }

    final structuredError = ffi.isAsync
        ? await ffi.async.getStructuredError()
        : ffi.sync.getStructuredError();
    if (structuredError != null) {
      return Failure<QueryResult, OdbcError>(
        QueryError(
          message: 'Streaming SQL error: ${structuredError.message}',
          sqlState: structuredError.sqlStateString,
          nativeCode: structuredError.nativeCode,
        ),
      );
    }

    final nativeError =
        ffi.isAsync ? await ffi.async.getError() : ffi.sync.getError();
    final message = nativeError.isNotEmpty && nativeError != 'No error'
        ? nativeError
        : normalizedMessage;
    return Failure<QueryResult, OdbcError>(QueryError(message: message));
  }

  Future<Result<Unit>> cancelStream(int streamId) async {
    if (streamId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final cancelled = ffi.isAsync
          ? await ffi.async.streamCancel(streamId)
          : ffi.sync.streamCancel(streamId);

      if (cancelled) {
        return const Success(unit);
      }

      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to cancel stream',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final requestId = ffi.isAsync
          ? await ffi.async.executeAsyncStart(
              nativeId,
              sql,
            )
          : ffi.sync.executeAsyncStart(nativeId, sql);
      final resolved = requestId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await ffi.convertNativeErrorToFailure<int>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to start async request',
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> asyncPoll(int requestId) async {
    if (requestId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final status = ffi.isAsync
          ? await ffi.async.asyncPoll(requestId)
          : ffi.sync.asyncPoll(requestId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) async {
    if (requestId <= 0) {
      return const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final data = ffi.isAsync
          ? await ffi.async.asyncGetResult(
              requestId,
              maxBufferBytes: maxBufferBytes,
            )
          : ffi.sync.asyncGetResult(requestId);
      final parsed = parser.parseBufferToQueryResult(data);
      if (parsed == null) {
        return await ffi.convertNativeErrorToFailure<QueryResult>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Async result is unavailable',
        );
      }
      return Success(parsed);
    } on Exception catch (e) {
      return Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> asyncCancel(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = ffi.isAsync
          ? await ffi.async.asyncCancel(requestId)
          : ffi.sync.asyncCancel(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) => QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to cancel async request',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> asyncFree(int requestId) async {
    if (requestId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid async request ID'),
      );
    }

    try {
      final ok = ffi.isAsync
          ? await ffi.async.asyncFree(requestId)
          : ffi.sync.asyncFree(requestId);
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) => QueryError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to free async request',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final streamId = ffi.isAsync
          ? await ffi.async.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
            )
          : ffi.sync.streamStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
            );
      final resolved = streamId ?? 0;
      if (resolved > 0) {
        return Success(resolved);
      }
      return await ffi.convertNativeErrorToFailure<int>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to start async stream',
      );
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<int>> streamPollAsync(int streamId) async {
    if (streamId <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid stream ID'),
      );
    }

    try {
      final status = ffi.isAsync
          ? await ffi.async.streamPollAsync(
              streamId,
            )
          : ffi.sync.streamPollAsync(streamId);
      final resolved = status ?? -1;
      return Success(resolved);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }
}
