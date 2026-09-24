import 'dart:async';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultItem;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart'
    show MultiResultStreamDecoder;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
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
    int? chunkSize,
  }) {
    final coalescer = MultiStreamCoalescer(_parser);
    return _streamQueryMulti<QueryResultMultiItem>(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      mapItems: coalescer.take,
      finish: coalescer.finish,
      fromFullItem: (item) => item,
    );
  }

  /// Streams one domain item per native fetch batch without accumulating rows
  /// from continuation frames. Use this for large multi-result cursors when
  /// bounded memory is more important than receiving one fully coalesced item
  /// per SQL cursor.
  Stream<Result<QueryResultMultiItem>> streamQueryMultiParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) {
    final coalescer = MultiStreamCoalescer(_parser);
    return _streamQueryMulti<QueryResultMultiItem>(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      params: params,
      mapItems: coalescer.take,
      finish: coalescer.finish,
      fromFullItem: (item) => item,
    );
  }

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatchesParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    int fetchSize = 1000,
    int? chunkSize,
  }) {
    final mapper = MultiStreamBatchMapper(_parser);
    return _streamQueryMulti<QueryResultMultiBatchItem>(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      params: params,
      mapItems: mapper.take,
      finish: mapper.finish,
      fromFullItem: _batchItemFromFull,
    );
  }

  Stream<Result<QueryResultMultiBatchItem>> streamQueryMultiBatches(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) {
    final mapper = MultiStreamBatchMapper(_parser);
    return _streamQueryMulti<QueryResultMultiBatchItem>(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: chunkSize,
      mapItems: mapper.take,
      finish: mapper.finish,
      fromFullItem: _batchItemFromFull,
    );
  }

  Stream<Result<T>> _streamQueryMulti<T extends Object>(
    String connectionId,
    String sql, {
    required int fetchSize,
    required int? chunkSize,
    required List<T> Function(Iterable<MultiResultItem> items) mapItems,
    required List<T> Function() finish,
    required T Function(QueryResultMultiItem item) fromFullItem,
    List<ParamValue> params = const <ParamValue>[],
  }) async* {
    final nativeId = _state.connectionIds[connectionId];
    if (nativeId == null) {
      yield Failure<T, OdbcError>(
        const ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final opts = _state.optionsFor(connectionId);
    final effectiveChunk = resolveStreamChunkSizeBytes(
      chunkSize: chunkSize,
      options: opts,
    );
    final lazyStrings = opts?.lazyStrings ?? false;
    // Multi-result item and batch APIs are row-shaped; keep row-major wire
    // and use streamQueryColumnar* for typed columnar streams.
    const resultEncoding = ResultEncoding.rowMajor;

    final supportsStreaming = _capability.supportsStreamQueryMulti;
    if (!supportsStreaming) {
      final fallback = await _query.executeQueryMultiFull(connectionId, sql);
      if (fallback.isError()) {
        final err = fallback.exceptionOrNull();
        yield Failure<T, OdbcError>(
          err is OdbcError ? err : QueryError(message: err.toString()),
        );
        return;
      }
      final items = fallback.getOrNull()!.items;
      for (final item in items) {
        yield Success<T, OdbcError>(fromFullItem(item));
      }
      return;
    }

    var streamId = 0;
    var completed = false;
    try {
      final serialized = params.isEmpty ? null : serializeParams(params);
      streamId = _ffi.isAsync
          ? await _ffi.async.streamMultiStartAsync(
              nativeId,
              sql,
              fetchSize: fetchSize,
              chunkSize: effectiveChunk,
              resultEncodingWire: resultEncoding.wireCode,
              serializedParams: serialized ?? const <int>[],
            )
          : (serialized == null
                  ? _ffi.sync.streamMultiStartBatched(
                      nativeId,
                      sql,
                      fetchSize: fetchSize,
                      chunkSize: effectiveChunk,
                      resultEncodingWire: resultEncoding.wireCode,
                    )
                  : _ffi.sync.streamMultiStartBatchedParams(
                      nativeId,
                      sql,
                      serialized,
                      fetchSize: fetchSize,
                      chunkSize: effectiveChunk,
                      resultEncodingWire: resultEncoding.wireCode,
                    )) ??
              0;
      if (streamId == 0) {
        final fallback = await _query.executeQueryMultiFull(connectionId, sql);
        if (fallback.isSuccess()) {
          for (final item in fallback.getOrNull()!.items) {
            yield Success<T, OdbcError>(fromFullItem(item));
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
        yield Failure<T, OdbcError>(
          QueryError(
            message: 'Failed to start streaming multi-result: $message',
            sqlState: structuredError?.sqlStateString,
            nativeCode: structuredError?.nativeCode,
          ),
        );
        return;
      }

      final decoder = MultiResultStreamDecoder(lazyStrings: lazyStrings);
      var streamFailed = false;

      final drive = _ffi.isAsync
          ? _driveAsyncMultiStream<T>(
              streamId: streamId,
              decoder: decoder,
              chunkSize: effectiveChunk,
              mapItems: mapItems,
            )
          : _driveSyncMultiStream<T>(
              streamId: streamId,
              decoder: decoder,
              chunkSize: effectiveChunk,
              mapItems: mapItems,
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
        yield Failure<T, OdbcError>(
          MalformedPayloadError(message: e.message),
        );
        return;
      }

      for (final item in finish()) {
        yield Success<T, OdbcError>(item);
      }
      completed = true;
    } on Exception catch (e) {
      yield Failure<T, OdbcError>(
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

  static QueryResultMultiBatchItem _batchItemFromFull(
    QueryResultMultiItem item,
  ) {
    final resultSet = item.resultSet;
    if (resultSet != null) {
      return QueryResultMultiBatchItem.resultSet(resultSet);
    }
    return QueryResultMultiBatchItem.rowCount(item.rowCount ?? 0);
  }

  Stream<Result<T>> _driveSyncMultiStream<T extends Object>({
    required int streamId,
    required MultiResultStreamDecoder decoder,
    required int chunkSize,
    required List<T> Function(Iterable<MultiResultItem> items) mapItems,
  }) async* {
    while (true) {
      final fetched = _ffi.sync.streamFetch(streamId, bufferSize: chunkSize);
      if (!fetched.success) {
        yield Failure<T, OdbcError>(
          QueryError(message: _ffi.sync.getError()),
        );
        return;
      }
      final data = fetched.data;
      if (data != null && data.isNotEmpty) {
        for (final item in mapItems(decoder.feed(data))) {
          yield Success<T, OdbcError>(item);
        }
      }
      if (!fetched.hasMore) {
        break;
      }
    }
  }

  Stream<Result<T>> _driveAsyncMultiStream<T extends Object>({
    required int streamId,
    required MultiResultStreamDecoder decoder,
    required int chunkSize,
    required List<T> Function(Iterable<MultiResultItem> items) mapItems,
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
        yield Failure<T, OdbcError>(
          QueryError(
            message: errMsg.isNotEmpty && errMsg != 'No error'
                ? errMsg
                : 'Async multi-result stream failed with status $status',
          ),
        );
        return;
      }
      if (status != _streamAsyncStatusReady) {
        yield Failure<T, OdbcError>(
          QueryError(message: 'Unexpected async stream status: $status'),
        );
        return;
      }

      if (!polled.success) {
        yield Failure<T, OdbcError>(
          QueryError(message: polled.error ?? 'Stream fetch failed'),
        );
        return;
      }
      final data = polled.data;
      if (data != null && data.isNotEmpty) {
        for (final item in mapItems(decoder.feed(data))) {
          yield Success<T, OdbcError>(item);
        }
      }
    }
  }

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _queryRunner.streamQuery(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _queryRunner.streamQueryNamed(
        connectionId,
        sql,
        namedParams,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Stream<ParsedRowBuffer> streamNativeQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    bool lazyStrings = false,
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _queryRunner.streamNativeQueryWithFallback(
        nativeId,
        sql,
        maxBufferBytes: maxBufferBytes,
        resultEncoding: resultEncoding,
        lazyStrings: lazyStrings,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Stream<TypedColumnarResult> streamNativeColumnarQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    bool lazyStrings = false,
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) =>
      _columnarRunner.streamNativeColumnarQueryWithFallback(
        nativeId,
        sql,
        maxBufferBytes: maxBufferBytes,
        lazyStrings: lazyStrings,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql, {
    int fetchSize = 1000,
    int? chunkSize,
  }) =>
      _columnarRunner.streamQueryColumnar(
        connectionId,
        sql,
        fetchSize: fetchSize,
        chunkSize: chunkSize,
      );

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
    int? chunkSize,
  }) {
    final effectiveChunk = resolveStreamChunkSizeBytes(
      chunkSize: chunkSize,
      options: _state.optionsFor(connectionId),
    );
    return _asyncLifecycle.streamStartAsync(
      connectionId,
      sql,
      fetchSize: fetchSize,
      chunkSize: effectiveChunk,
    );
  }

  Future<Result<int>> streamPollAsync(int streamId) =>
      _asyncLifecycle.streamPollAsync(streamId);
}
