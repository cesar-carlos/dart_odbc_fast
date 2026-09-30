import 'dart:async';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
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
    return error is OdbcError && error.code == OdbcErrorCode.timeout;
  }

  bool isStreamingProtocolException(
    Exception error,
    String normalizedMessage,
  ) {
    if (error is FormatException) {
      return true;
    }
    return error is OdbcError && error.code == OdbcErrorCode.protocol;
  }

  bool isStreamingInterruptionException(Exception error) {
    return error is AsyncError && error.code == AsyncErrorCode.workerTerminated;
  }

  Future<Failure<QueryResult, OdbcError>> streamingFailureFromException(
    Exception error,
  ) async {
    return Failure(translateOdbcError(error, operation: 'streamQuery'));
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
