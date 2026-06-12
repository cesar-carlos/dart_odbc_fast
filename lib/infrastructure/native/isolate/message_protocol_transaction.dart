part of 'message_protocol.dart';

class BeginTransactionRequest extends WorkerRequest {
  const BeginTransactionRequest(
    int requestId,
    this.connectionId,
    this.isolationLevel, {
    this.savepointDialect = 0,
    this.accessMode = 0,
    this.lockTimeoutMs = 0,
  }) : super(requestId, RequestType.beginTransaction);
  final int connectionId;
  final int isolationLevel;

  /// Wire code from `SavepointDialect.code` (`0=auto`, `1=sqlServer`,
  /// `2=sql92`). Default is `auto` so legacy callers keep working.
  final int savepointDialect;

  /// Wire code from `TransactionAccessMode.code` (`0=readWrite`,
  /// `1=readOnly`). Default is `readWrite` so legacy callers keep
  /// working unchanged. Sprint 4.1.
  final int accessMode;

  /// Per-transaction lock timeout in milliseconds. `0` = engine default
  /// (no override). Default is `0` so legacy callers keep working
  /// unchanged. Sprint 4.2.
  final int lockTimeoutMs;
}

/// Commit transaction.
class CommitTransactionRequest extends WorkerRequest {
  const CommitTransactionRequest(int requestId, this.txnId)
      : super(requestId, RequestType.commitTransaction);
  final int txnId;
}

/// Rollback transaction.
class RollbackTransactionRequest extends WorkerRequest {
  const RollbackTransactionRequest(int requestId, this.txnId)
      : super(requestId, RequestType.rollbackTransaction);
  final int txnId;
}

/// Create savepoint.
class SavepointCreateRequest extends WorkerRequest {
  const SavepointCreateRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointCreate);
  final int txnId;
  final String name;
}

/// Rollback to savepoint.
class SavepointRollbackRequest extends WorkerRequest {
  const SavepointRollbackRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointRollback);
  final int txnId;
  final String name;
}

/// Release savepoint.
class SavepointReleaseRequest extends WorkerRequest {
  const SavepointReleaseRequest(int requestId, this.txnId, this.name)
      : super(requestId, RequestType.savepointRelease);
  final int txnId;
  final String name;
}

/// Prepare SQL statement.
