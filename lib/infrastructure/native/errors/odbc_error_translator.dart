import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';

/// Single conversion point for thrown errors crossing the native boundary.
OdbcError translateOdbcError(
  Object error, {
  required String operation,
  StackTrace? stackTrace,
}) =>
    normalizeOdbcError(
      NativeCallContext.takeFailure() ??
          (error is AsyncError ? error.toOdbcError() : error),
      operation: operation,
      stackTrace: stackTrace,
    );
