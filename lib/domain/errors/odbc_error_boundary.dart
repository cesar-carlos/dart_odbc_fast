import 'dart:async';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';

/// Converts failures only at contracts that promise a Result.
class OdbcErrorBoundary {
  OdbcErrorBoundary._();

  static Future<Result<T>> run<T extends Object>(
    String operation,
    Future<Result<T>> Function() action,
  ) async {
    try {
      final result = await action();
      if (result.isSuccess()) return result;
      return Failure(
        normalizeOdbcError(result.exceptionOrNull()!, operation: operation),
      );
    } on Object catch (error, stackTrace) {
      return Failure(
        normalizeOdbcError(
          error,
          operation: operation,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  static Future<Result<void>> runVoid(
    String operation,
    Future<Result<void>> Function() action,
  ) async {
    try {
      final result = await action();
      if (result.isSuccess()) return result;
      return Failure<Unit, OdbcError>(
        normalizeOdbcError(
          result.exceptionOrNull()!,
          operation: operation,
        ),
      );
    } on Object catch (error, stackTrace) {
      return Failure<Unit, OdbcError>(
        normalizeOdbcError(
          error,
          operation: operation,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  static Stream<Result<T>> stream<T extends Object>(
    String operation,
    Stream<Result<T>> Function() source,
  ) async* {
    OdbcError? terminal;
    try {
      await for (final result in source()) {
        if (result.isError()) {
          terminal = normalizeOdbcError(
            result.exceptionOrNull()!,
            operation: operation,
          );
          break;
        }
        yield result;
      }
    } on Object catch (error, stackTrace) {
      final failure = normalizeOdbcError(
        error,
        operation: operation,
        stackTrace: stackTrace,
      );
      terminal = terminal?.withSecondary(failure) ?? failure;
    }
    if (terminal != null) yield Failure(terminal);
  }
}

/// Infrastructure exceptions are converted to OdbcError before this boundary.
OdbcError normalizeOdbcError(
  Object error, {
  required String operation,
  StackTrace? stackTrace,
}) {
  if (error is OdbcErrorConvertible) {
    return normalizeOdbcError(
      error.toOdbcError(),
      operation: operation,
      stackTrace: stackTrace,
    );
  }
  if (error is OdbcError) {
    return error.withDetails(
      error.details.copyWith(
        operation: error.details.operation ?? operation,
        stackTrace: error.details.stackTrace ?? stackTrace,
      ),
      message:
          error.message.trim().isEmpty || error.message.trim() == 'No error'
              ? 'Failed to complete $operation'
              : null,
    );
  }
  final details = OdbcErrorDetails(
    operation: operation,
    cause: error,
    stackTrace: stackTrace,
  );
  if (error is TimeoutException) {
    return QueryError(
      message: 'The operation timed out',
      details: details.copyWith(
        code: OdbcErrorCode.timeout,
        outcomeUnknown: true,
      ),
    );
  }
  if (error is FormatException) {
    return MalformedPayloadError(
      message: error.message.trim().isEmpty
          ? 'Invalid response during $operation'
          : error.message,
      details: details.copyWith(code: OdbcErrorCode.protocol),
    );
  }
  if (error is UnsupportedError) {
    return UnsupportedFeatureError(
      message: 'The operation is not supported',
      details: details.copyWith(code: OdbcErrorCode.unsupported),
    );
  }
  return QueryError(
    message: 'Unexpected failure during $operation',
    details: details.copyWith(code: OdbcErrorCode.internal),
  );
}
