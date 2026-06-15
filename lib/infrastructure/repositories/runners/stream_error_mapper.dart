import 'dart:async';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Maps streaming exceptions to typed repository failures.
class StreamErrorMapper {
  const StreamErrorMapper(this.ffi);

  final OdbcFfiDispatch ffi;

  bool isStreamingTimeoutException(
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

  bool isStreamingProtocolException(
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

  bool isStreamingInterruptionException(Exception error) {
    return error is AsyncError && error.code == AsyncErrorCode.workerTerminated;
  }

  Future<Failure<QueryResult, OdbcError>> streamingFailureFromException(
    Exception error,
  ) async {
    final normalizedMessage = error.toString();
    if (isStreamingTimeoutException(error, normalizedMessage)) {
      return const Failure<QueryResult, OdbcError>(
        QueryError(message: odbcQueryTimedOutMessage),
      );
    }

    if (isStreamingProtocolException(error, normalizedMessage)) {
      return Failure<QueryResult, OdbcError>(
        QueryError(
          message: '$odbcStreamProtocolErrorPrefix: $normalizedMessage',
        ),
      );
    }

    if (isStreamingInterruptionException(error)) {
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

  Future<Failure<TypedColumnarResult, OdbcError>>
      streamingColumnarFailureFromException(
    Exception error,
  ) async {
    final base = await streamingFailureFromException(error);
    return base.fold(
      (_) => const Failure<TypedColumnarResult, OdbcError>(
        QueryError(message: 'Unexpected success in columnar stream failure'),
      ),
      Failure<TypedColumnarResult, OdbcError>.new,
    );
  }
}
