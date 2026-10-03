import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_execution_stage.dart';

enum WorkerErrorKind {
  connection,
  query,
  validation,
  unsupported,
  environment,
  noMoreResults,
  protocol,
  rollback,
  resourceLimit,
  cancelled,
  worker,
  bulkPartial,
}

/// Sendable diagnostic captured on the worker at the failing call.
class WorkerFailureSnapshot {
  const WorkerFailureSnapshot({
    required this.message,
    required this.operation,
    required this.requestId,
    this.connectionId,
    this.sqlState,
    this.nativeCode,
    this.code = OdbcErrorCode.query,
    this.cause,
    this.stackTrace,
    this.secondary,
    this.outcomeUnknown = false,
    this.secondaryErrors = const [],
    this.rowsInsertedBeforeFailure,
    this.failedChunks,
    this.bulkDetail,
    this.kind,
    this.executionStage,
  });
  factory WorkerFailureSnapshot.fromError(
    OdbcError error, {
    required int requestId,
  }) =>
      WorkerFailureSnapshot(
        message: error.message,
        operation: error.details.operation ?? 'nativeOperation',
        requestId: requestId,
        sqlState: error.sqlState,
        nativeCode: error.nativeCode,
        code: error.code,
        cause: error.details.cause?.toString(),
        stackTrace: error.details.stackTrace?.toString(),
        outcomeUnknown: error.details.outcomeUnknown,
        rowsInsertedBeforeFailure: error is BulkPartialFailureError
            ? error.rowsInsertedBeforeFailure
            : null,
        failedChunks:
            error is BulkPartialFailureError ? error.failedChunks : null,
        bulkDetail: error is BulkPartialFailureError ? error.detail : null,
        kind: kindOf(error),
        secondaryErrors: [
          for (final secondary in error.details.secondaryErrors)
            WorkerFailureSnapshot.fromError(secondary, requestId: requestId),
        ],
      );

  final String message;
  final String operation;
  final int requestId;
  final int? connectionId;
  final String? sqlState;
  final int? nativeCode;
  final OdbcErrorCode code;
  final String? cause;
  final String? stackTrace;
  final String? secondary;
  final bool outcomeUnknown;
  final List<WorkerFailureSnapshot> secondaryErrors;
  final int? rowsInsertedBeforeFailure;
  final int? failedChunks;
  final String? bulkDetail;
  final WorkerErrorKind? kind;
  final NativeExecutionStage? executionStage;

  static WorkerErrorKind kindOf(OdbcError error) => switch (error) {
        ConnectionError() => WorkerErrorKind.connection,
        QueryError() => WorkerErrorKind.query,
        ValidationError() => WorkerErrorKind.validation,
        UnsupportedFeatureError() => WorkerErrorKind.unsupported,
        EnvironmentNotInitializedError() => WorkerErrorKind.environment,
        NoMoreResultsError() => WorkerErrorKind.noMoreResults,
        MalformedPayloadError() => WorkerErrorKind.protocol,
        RollbackFailedError() => WorkerErrorKind.rollback,
        ResourceLimitReachedError() => WorkerErrorKind.resourceLimit,
        CancelledError() => WorkerErrorKind.cancelled,
        WorkerCrashedError() => WorkerErrorKind.worker,
        BulkPartialFailureError() => WorkerErrorKind.bulkPartial,
      };

  OdbcError toError(int workerId) {
    final details = OdbcErrorDetails(
      operation: operation,
      requestId: requestId,
      workerId: workerId,
      connectionId: connectionId?.toString(),
      cause: cause,
      stackTrace:
          stackTrace == null ? null : StackTrace.fromString(stackTrace!),
      code: code,
      outcomeUnknown: outcomeUnknown,
      secondaryErrors: [
        for (final error in secondaryErrors) error.toError(workerId),
        if (secondary != null)
          QueryError(
            message: 'Failed to collect native diagnostic',
            details: OdbcErrorDetails(
              code: OdbcErrorCode.internal,
              cause: secondary,
            ),
          ),
      ],
    );
    if (rowsInsertedBeforeFailure != null &&
        failedChunks != null &&
        bulkDetail != null) {
      return BulkPartialFailureError(
        rowsInsertedBeforeFailure: rowsInsertedBeforeFailure!,
        failedChunks: failedChunks!,
        detail: bulkDetail!,
        sqlState: sqlState,
        nativeCode: nativeCode,
        details: details,
      );
    }
    final error = QueryError(
      message: message,
      sqlState: sqlState,
      nativeCode: nativeCode,
      details: details,
    );
    final variant = kind ??
        switch (code) {
          OdbcErrorCode.connection => WorkerErrorKind.connection,
          OdbcErrorCode.validation => WorkerErrorKind.validation,
          OdbcErrorCode.resourceLimit => WorkerErrorKind.resourceLimit,
          OdbcErrorCode.protocol => WorkerErrorKind.protocol,
          OdbcErrorCode.unsupported => WorkerErrorKind.unsupported,
          OdbcErrorCode.cancelled => WorkerErrorKind.cancelled,
          OdbcErrorCode.environmentUnavailable => WorkerErrorKind.environment,
          _ => WorkerErrorKind.query,
        };
    return switch (variant) {
      WorkerErrorKind.connection => ConnectionError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.validation => ValidationError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.resourceLimit => ResourceLimitReachedError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.protocol => MalformedPayloadError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.unsupported => UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.cancelled => CancelledError(
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.environment => EnvironmentNotInitializedError(
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.rollback => RollbackFailedError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.worker => WorkerCrashedError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.noMoreResults => NoMoreResultsError(
          sqlState: sqlState,
          nativeCode: nativeCode,
          details: details,
        ),
      WorkerErrorKind.query => error,
      WorkerErrorKind.bulkPartial => MalformedPayloadError(
          message: 'Incomplete partial-insert diagnostic',
          details: details.copyWith(code: OdbcErrorCode.protocol),
        ),
    };
  }
}
