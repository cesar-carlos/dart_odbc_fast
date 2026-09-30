import 'package:odbc_fast/domain/errors/odbc_error.dart';

/// Stable categories suitable for application localization.
enum OdbcErrorCode {
  validation,
  environmentUnavailable,
  connection,
  query,
  transaction,
  timeout,
  cancelled,
  protocol,
  unsupported,
  resourceLimit,
  workerInterrupted,
  cleanup,
  internal,
}

/// Technical context. Presentation code should use OdbcError.userMessage.
class OdbcErrorDetails {
  const OdbcErrorDetails({
    this.code,
    this.operation,
    this.cause,
    this.stackTrace,
    this.transactionId,
    this.connectionId,
    this.requestId,
    this.workerId,
    this.attempt,
    this.outcomeUnknown = false,
    this.secondaryErrors = const [],
  });

  final OdbcErrorCode? code;
  final String? operation;
  final Object? cause;
  final StackTrace? stackTrace;
  final String? transactionId;
  final String? connectionId;
  final int? requestId;
  final int? workerId;
  final int? attempt;
  final bool outcomeUnknown;
  final List<OdbcError> secondaryErrors;

  OdbcErrorDetails copyWith({
    OdbcErrorCode? code,
    String? operation,
    Object? cause,
    StackTrace? stackTrace,
    String? transactionId,
    String? connectionId,
    int? requestId,
    int? workerId,
    int? attempt,
    bool? outcomeUnknown,
    List<OdbcError>? secondaryErrors,
  }) =>
      OdbcErrorDetails(
        code: code ?? this.code,
        operation: operation ?? this.operation,
        cause: cause ?? this.cause,
        stackTrace: stackTrace ?? this.stackTrace,
        transactionId: transactionId ?? this.transactionId,
        connectionId: connectionId ?? this.connectionId,
        requestId: requestId ?? this.requestId,
        workerId: workerId ?? this.workerId,
        attempt: attempt ?? this.attempt,
        outcomeUnknown: outcomeUnknown ?? this.outcomeUnknown,
        secondaryErrors:
            List.unmodifiable(secondaryErrors ?? this.secondaryErrors),
      );
}
