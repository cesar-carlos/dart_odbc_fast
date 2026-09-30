import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';

/// Runs every cleanup step, preserving the operation's primary failure.
Future<OdbcError?> cleanupNativeResources(
  List<({String operation, Future<bool> Function() action})> steps, {
  OdbcError? primary,
}) async {
  var combined = primary;
  for (final step in steps) {
    OdbcError? failure;
    try {
      if (!await step.action()) {
        failure = NativeCallContext.takeFailure() ??
            QueryError(
              message: 'Failed to release native resources',
              details: OdbcErrorDetails(
                operation: step.operation,
                code: OdbcErrorCode.cleanup,
              ),
            );
      }
    } on Object catch (error, stack) {
      failure = translateOdbcError(
        error,
        operation: step.operation,
        stackTrace: stack,
      );
    }
    if (failure != null) {
      failure = failure.withDetails(
        failure.details
            .copyWith(code: OdbcErrorCode.cleanup, operation: step.operation),
      );
      combined = combined?.withSecondary(failure) ?? failure;
    }
  }
  return combined;
}
