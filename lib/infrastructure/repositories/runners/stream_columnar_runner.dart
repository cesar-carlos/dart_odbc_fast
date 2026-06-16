import 'dart:async';

import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/query_timeout_helpers.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_error_mapper.dart';
import 'package:result_dart/result_dart.dart';

/// Columnar batched streaming (`odbc_stream_start_batched_options`).
class StreamColumnarRunner {
  StreamColumnarRunner({
    required this.ffi,
    required this.state,
    required StreamErrorMapper errors,
  }) : _errors = errors;

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final StreamErrorMapper _errors;

  Stream<TypedColumnarResult> streamNativeColumnarQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    bool lazyStrings = false,
    ResultEncoding resultEncoding = ResultEncoding.columnar,
  }) async* {
    final batched = ffi.isAsync
        ? ffi.async.streamQueryColumnarBatched(
            nativeId,
            sql,
            maxBufferBytes: maxBufferBytes,
            lazyStrings: lazyStrings,
            resultEncoding: resultEncoding,
          )
        : ffi.sync.streamQueryColumnarBatched(
            nativeId,
            sql,
            lazyStrings: lazyStrings,
            resultEncoding: resultEncoding,
          );

    await for (final chunk in batched) {
      yield chunk;
    }
  }

  Stream<Result<TypedColumnarResult>> streamQueryColumnar(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<TypedColumnarResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final queryTimeout = opts?.queryTimeout;
    final lazyStrings = opts?.lazyStrings ?? false;
    final encoding = state.defaultResultEncoding.isColumnar
        ? state.defaultResultEncoding
        : ResultEncoding.columnar;

    Stream<Result<TypedColumnarResult>> createSource() async* {
      try {
        await for (final chunk in streamNativeColumnarQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: maxBytes,
          lazyStrings: lazyStrings,
          resultEncoding: encoding,
        )) {
          yield Success(chunk);
        }
      } on Exception catch (e) {
        yield await _errors.streamingColumnarFailureFromException(e);
      }
    }

    final source = createSource();

    yield* streamWithQueryTimeout(
      source: source,
      queryTimeout: queryTimeout,
      onTimeoutItem: const Failure<TypedColumnarResult, OdbcError>(
        QueryError(message: odbcQueryTimedOutMessage),
      ),
    );
  }
}
