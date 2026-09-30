import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/domain/repositories/i_transaction_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction / savepoint / XA capability delegate for the ODBC service façade.
class OdbcTransactionService {
  OdbcTransactionService(this._repository);

  final ITransactionRepository _repository;

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run(
        'beginTransaction',
        () => _repository.beginTransaction(
          connectionId,
          isolationLevel ?? IsolationLevel.readCommitted,
          savepointDialect: savepointDialect ?? SavepointDialect.auto,
          accessMode: accessMode ?? TransactionAccessMode.readWrite,
          lockTimeout: lockTimeout,
        ),
      );

  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      OdbcErrorBoundary.runVoid(
        'commitTransaction',
        () => _repository.commitTransaction(connectionId, txnId),
      );

  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      OdbcErrorBoundary.runVoid(
        'rollbackTransaction',
        () => _repository.rollbackTransaction(connectionId, txnId),
      );

  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      OdbcErrorBoundary.run('runInTransaction', () async {
        final beginResult = await beginTransaction(
          connectionId,
          isolationLevel: isolationLevel,
          savepointDialect: savepointDialect,
          accessMode: accessMode,
          lockTimeout: lockTimeout,
        );
        if (beginResult.isError()) {
          return Failure(beginResult.exceptionOrNull()!);
        }
        final txnId = beginResult.getOrNull()!;

        final userResult = await OdbcErrorBoundary.run(
          'transactionAction',
          () => action(txnId),
        );
        if (userResult.isError()) {
          var error = normalizeOdbcError(
            userResult.exceptionOrNull()!,
            operation: 'transactionAction',
          );
          final rollback = await rollbackTransaction(connectionId, txnId);
          if (rollback.isError()) {
            error = error.withSecondary(
              normalizeOdbcError(
                rollback.exceptionOrNull()!,
                operation: 'rollbackTransaction',
              ),
            );
          }
          return Failure(error);
        }
        final commit = await commitTransaction(connectionId, txnId);
        if (commit.isError()) return Failure(commit.exceptionOrNull()!);
        return userResult;
      });

  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) =>
      OdbcErrorBoundary.run('runInXaTransaction', () async {
        final start = await xaStart(connectionId, xid);
        if (start.isError()) return Failure(start.exceptionOrNull()!);
        final xa = start.getOrNull()!;
        final userResult =
            await OdbcErrorBoundary.run('xaAction', () => action(xa));
        if (userResult.isError()) {
          return Failure(
            await _xaAbort(
              xa,
              normalizeOdbcError(
                userResult.exceptionOrNull()!,
                operation: 'xaAction',
              ),
            ),
          );
        }
        Future<OdbcError?> phase(
          String operation,
          Future<bool> Function() invoke,
        ) async {
          try {
            if (await invoke()) return null;
            final original = xa.lastError ??
                QueryError(
                  message: 'The XA transaction phase failed',
                  details: OdbcErrorDetails(
                    operation: operation,
                    code: OdbcErrorCode.transaction,
                    transactionId: xid.toString(),
                    outcomeUnknown: operation == 'xaCommitPrepared' ||
                        operation == 'xaCommitOnePhase',
                  ),
                );
            return original.withDetails(
              original.details.copyWith(
                operation: operation,
                code: OdbcErrorCode.transaction,
                transactionId: xid.toString(),
                outcomeUnknown: operation == 'xaCommitPrepared' ||
                    operation == 'xaCommitOnePhase',
              ),
            );
          } on Object catch (error, stack) {
            final primary = normalizeOdbcError(
              error,
              operation: operation,
              stackTrace: stack,
            );
            return primary.withDetails(
              primary.details.copyWith(
                transactionId: xid.toString(),
                outcomeUnknown: operation == 'xaCommitPrepared' ||
                    operation == 'xaCommitOnePhase',
              ),
            );
          }
        }

        if (onePhase) {
          final error = await phase('xaCommitOnePhase', xa.commitOnePhase);
          if (error != null) return Failure(error);
          return userResult;
        }
        final end = await phase('xaEnd', xa.end);
        if (end != null) return Failure(await _xaAbort(xa, end));
        final prepare = await phase('xaPrepare', xa.prepare);
        if (prepare != null) return Failure(await _xaAbort(xa, prepare));
        final commit = await phase('xaCommitPrepared', xa.commitPrepared);
        if (commit != null) return Failure(commit);
        return userResult;
      });

  Future<Result<XaTransactionHandle>> xaStart(String connectionId, Xid xid) =>
      OdbcErrorBoundary.run(
        'xaStart',
        () => _repository.xaStart(connectionId, xid),
      );

  Future<Result<List<Xid>>> xaRecover(String connectionId) =>
      OdbcErrorBoundary.run(
        'xaRecover',
        () => _repository.xaRecover(connectionId),
      );

  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  ) =>
      OdbcErrorBoundary.run(
        'xaResumePrepared',
        () => _repository.xaResumePrepared(connectionId, xid),
      );

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'createSavepoint',
        () => _repository.createSavepoint(connectionId, txnId, name),
      );

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'rollbackToSavepoint',
        () => _repository.rollbackToSavepoint(connectionId, txnId, name),
      );

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      OdbcErrorBoundary.runVoid(
        'releaseSavepoint',
        () => _repository.releaseSavepoint(connectionId, txnId, name),
      );

  Future<OdbcError> _xaAbort(XaTransactionHandle xa, OdbcError primary) async {
    var combined = primary;
    try {
      if (xa.state == XaState.active && !await xa.end()) {
        combined = combined.withSecondary(
          const QueryError(
            message: 'XA end failed during cleanup',
            details: OdbcErrorDetails(
              code: OdbcErrorCode.cleanup,
              operation: 'xaEnd',
            ),
          ),
        );
      }
      if (xa.state == XaState.failedAfterPrepare) {
        return combined.withDetails(
          combined.details
              .copyWith(outcomeUnknown: true, transactionId: xa.xid.toString()),
        );
      }
      final ok = xa.state == XaState.prepared
          ? await xa.rollbackPrepared()
          : await xa.rollback();
      if (!ok) {
        combined = combined.withSecondary(
          xa.lastError ??
              const RollbackFailedError(message: 'XA rollback failed'),
        );
      }
    } on Object catch (error, stack) {
      combined = combined.withSecondary(
        normalizeOdbcError(
          error,
          operation: 'xaRollback',
          stackTrace: stack,
        ),
      );
    }
    return combined;
  }
}
