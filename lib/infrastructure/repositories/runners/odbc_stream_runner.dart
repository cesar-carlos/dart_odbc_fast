import 'dart:async';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart'
    show MultiResultStreamDecoder;
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/multi_stream_coalescer.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_async_lifecycle_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_capability_policy.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_columnar_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_error_mapper.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_query_runner.dart';
import 'package:result_dart/result_dart.dart';

/// Async stream poll status codes (mirrors native `odbc_stream_poll_async`).
const int _streamAsyncStatusPending = 0;
const int _streamAsyncStatusReady = 1;
const int _streamAsyncStatusDone = 2;
const int _streamAsyncStatusError = -1;
const int _streamAsyncStatusCancelled = -2;
const Duration _pollBackoffMin = Duration(milliseconds: 1);
const Duration _pollBackoffMax = Duration(milliseconds: 10);

/// Thin façade over focused stream runners.
class OdbcStreamRunner {
  OdbcStreamRunner({
    required OdbcFfiDispatch ffi,
    required OdbcRepositoryState state,
    // Wired by OdbcRepositoryImpl; reserved for reconnect-aware streaming.
    // ignore: avoid_unused_constructor_parameters
    required OdbcConnectionRunner connection,
    required OdbcResultParser parser,
    required OdbcQueryRunner query,
  })  : _ffi = ffi,
        _state = state,
        _parser = parser,
        _query = query,
        _capability = StreamCapabilityPolicy(ffi),
        _errors = StreamErrorMapper(ffi),
        _asyncLifecycle = StreamAsyncLifecycleRunner(
          ffi: ffi,
          state: state,
          parser: parser,
        ) {
    _columnarRunner = StreamColumnarRunner(
      ffi: ffi,
      state: state,
      errors: _errors,
    );
    _queryRunner = StreamQueryRunner(
      ffi: ffi,
      state: state,
      parser: parser,
      query: query,
      errors: _errors,
    );
  }

  final OdbcFfiDispatch _ffi;
  final OdbcRepositoryState _state;
  final OdbcResultParser _parser;
  final OdbcQueryRunner _query;
  final StreamCapabilityPolicy _capability;
  final StreamErrorMapper _errors;
  final StreamAsyncLifecycleRunner _asyncLifecycle;
  late final StreamColumnarRunner _columnarRunner;
  late final StreamQueryRunner _queryRunner;

  Stream<Result<QueryResultMultiItem>> streamQueryMulti(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async* {
    final nativeId = _state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResultMultiItem, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final lazyStrings = _state.optionsFor(connectionId)?.lazyStrings ?? false;
    // Multi-result items are row-shaped QueryResultMultiItem values; keep
    // row-major wire and use streamQueryColumnar* for typed columnar.
    const resultEncoding = ResultEncoding.rowMajor;

    final supportsStreaming = _capability.supportsStreamQueryMulti;
    if (!supportsStreaming) {
      final fallback = await _query.executeQueryMultiFull(connectionId, sql);
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
    var completed = false;
    try {
      streamId = _ffi.isAsync
          ? await _ffi.async.streamMultiStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: chunkSize,
              resultEncodingWire: resultEncoding.wireCode,
            )
          : _ffi.sync.streamMultiStartBatched(
                nativeId,
                sql,
                fetchSize: fetchSize,
                chunkSize: chunkSize,
                resultEncodingWire: resultEncoding.wireCode,
              ) ??
              0;
      if (streamId == 0) {
        final fallback = await _query.executeQueryMultiFull(connectionId, sql);
        if (fallback.isSuccess()) {
          for (final item in fallback.getOrNull()!.items) {
            yield Success<QueryResultMultiItem, OdbcError>(item);
          }
          return;
        }
        final structuredError = await _ffi.getStructuredNativeError(
          nativeConnectionId: nativeId,
        );
        final nativeErr = structuredError?.message ??
            (_ffi.isAsync ? await _ffi.async.getError() : _ffi.sync.getError());
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

      final decoder = MultiResultStreamDecoder(lazyStrings: lazyStrings);
      final coalescer = MultiStreamCoalescer(_parser);
      var streamFailed = false;

      final drive = _ffi.isAsync
          ? _driveAsyncMultiStream(
              streamId: streamId,
              decoder: decoder,
              coalescer: coalescer,
              chunkSize: chunkSize,
            )
          : _driveSyncMultiStream(
              streamId: streamId,
              decoder: decoder,
              coalescer: coalescer,
              chunkSize: chunkSize,
            );
      await for (final chunk in drive) {
        yield chunk;
        if (chunk.isError()) {
          streamFailed = true;
          break;
        }
      }
      if (streamFailed) {
        return;
      }

      try {
        decoder.assertExhausted();
      } on FormatException catch (e) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          MalformedPayloadError(message: e.message),
        );
        return;
      }

      for (final item in coalescer.finish()) {
        yield Success<QueryResultMultiItem, OdbcError>(item);
      }
      completed = true;
    } on Exception catch (e) {
      yield Failure<QueryResultMultiItem, OdbcError>(
        QueryError(message: e.toString()),
      );
    } finally {
      if (streamId != 0) {
        if (!completed) {
          try {
            if (_ffi.isAsync) {
              await _ffi.async.streamCancel(streamId);
            } else {
              _ffi.sync.streamCancel(streamId);
            }
          } on Object {
            // Best-effort; always attempt streamClose below.
          }
        }
        if (_ffi.isAsync) {
          await _ffi.async.streamClose(streamId);
        } else {
          _ffi.sync.streamClose(streamId);
        }
      }
    }
  }

  Stream<Result<QueryResultMultiItem>> _driveSyncMultiStream({
    required int streamId,
    required MultiResultStreamDecoder decoder,
    required MultiStreamCoalescer coalescer,
    required int chunkSize,
  }) async* {
    while (true) {
      final fetched = _ffi.sync.streamFetch(streamId, bufferSize: chunkSize);
      if (!fetched.success) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(message: _ffi.sync.getError()),
        );
        return;
      }
      final data = fetched.data;
      if (data != null && data.isNotEmpty) {
        for (final item in coalescer.take(decoder.feed(data))) {
          yield Success<QueryResultMultiItem, OdbcError>(item);
        }
      }
      if (!fetched.hasMore) {
        break;
      }
    }
  }

  Stream<Result<QueryResultMultiItem>> _driveAsyncMultiStream({
    required int streamId,
    required MultiResultStreamDecoder decoder,
    required MultiStreamCoalescer coalescer,
    required int chunkSize,
  }) async* {
    var streamDelay = _pollBackoffMin;
    while (true) {
      final polled = await _ffi.async.streamPollAndFetch(
        streamId,
        bufferSize: chunkSize,
      );
      final status = polled.status;
      if (status == _streamAsyncStatusPending) {
        await Future<void>.delayed(streamDelay);
        if (streamDelay < _pollBackoffMax) {
          streamDelay = Duration(
            microseconds: (streamDelay.inMicroseconds * 2)
                .clamp(0, _pollBackoffMax.inMicroseconds),
          );
        }
        continue;
      }
      streamDelay = _pollBackoffMin;
      if (status == _streamAsyncStatusDone) {
        break;
      }
      if (status == _streamAsyncStatusError ||
          status == _streamAsyncStatusCancelled) {
        final errMsg = await _ffi.async.getError();
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(
            message: errMsg.isNotEmpty && errMsg != 'No error'
                ? errMsg
                : 'Async multi-result stream failed with status $status',
          ),
        );
        return;
      }
      if (status != _streamAsyncStatusReady) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(message: 'Unexpected async stream status: $status'),
        );
        return;
      }

      if (!polled.success) {
        yield Failure<QueryResultMultiItem, OdbcError>(
          QueryError(message: polled.error ?? 'Stream fetch failed'),
        );
        return;
      }
      final data = polled.data;
      if (data != null && data.isNotEmpty) {
        for (final item in coalescer.take(decoder.feed(data))) {
          yield Success<QueryResultMultiItem, OdbcError>(item);
        }
      }
    }
  }

  Stream<Result<QueryResult>> streamQuery(String connectionId, String sql) =>
      _queryRunner.streamQuery(connectionId, sql);

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) =>
      _queryRunner.streamQueryNamed(connectionId, sql, namedParams);

  Stream<ParsedRowBuffer> streamNativeQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    bool lazyStrings = false,
  }) =>
      _queryRunner.streamNativeQueryWithFallback(
        nativeId,
        sql,
        maxBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
        lazyStrings: lazyStrings,
      );

  Stream<TypedColumnarResult> streamNativeColumnarQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    bool lazyStrings = false,
  }) =>
      _columnarRunner.streamNativeColumnarQueryWithFallback(
        nativeId,
        sql,
        maxBufferBytes: maxBufferBytes,
        lazyStrings: lazyStrings,
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) =>
      _columnarRunner.streamQueryColumnar(connectionId, sql);

  Future<Failure<QueryResult, OdbcError>> streamingFailureFromException(
    Exception error,
  ) =>
      _errors.streamingFailureFromException(error);

  Future<Result<Unit>> cancelStream(int streamId) =>
      _asyncLifecycle.cancelStream(streamId);

  Future<Result<int>> executeAsyncStart(String connectionId, String sql) =>
      _asyncLifecycle.executeAsyncStart(connectionId, sql);

  Future<Result<int>> asyncPoll(int requestId) =>
      _asyncLifecycle.asyncPoll(requestId);

  Future<Result<QueryResult>> asyncGetResult(
    int requestId, {
    int? maxBufferBytes,
  }) =>
      _asyncLifecycle.asyncGetResult(
        requestId,
        maxBufferBytes: maxBufferBytes,
      );

  Future<Result<Unit>> asyncCancel(int requestId) =>
      _asyncLifecycle.asyncCancel(requestId);

  Future<Result<Unit>> asyncFree(int requestId) =>
      _asyncLifecycle.asyncFree(requestId);

  Future<Result<int>> streamStartAsync(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _asyncLifecycle.streamStartAsync(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Future<Result<int>> streamPollAsync(int streamId) =>
      _asyncLifecycle.streamPollAsync(streamId);
}
