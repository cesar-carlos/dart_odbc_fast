import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction / savepoint / XA capability delegate for the ODBC service façade.
class OdbcTransactionService {
  OdbcTransactionService(this._repository);

  final IOdbcRepository _repository;

  Future<Result<int>> beginTransaction(
    String connectionId, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) =>
      _repository.beginTransaction(
        connectionId,
        isolationLevel ?? IsolationLevel.readCommitted,
        savepointDialect: savepointDialect ?? SavepointDialect.auto,
        accessMode: accessMode ?? TransactionAccessMode.readWrite,
        lockTimeout: lockTimeout,
      );

  Future<Result<void>> commitTransaction(String connectionId, int txnId) =>
      _repository.commitTransaction(connectionId, txnId);

  Future<Result<void>> rollbackTransaction(String connectionId, int txnId) =>
      _repository.rollbackTransaction(connectionId, txnId);

  Future<Result<T>> runInTransaction<T extends Object>(
    String connectionId,
    Future<Result<T>> Function(int txnId) action, {
    IsolationLevel? isolationLevel,
    SavepointDialect? savepointDialect,
    TransactionAccessMode? accessMode,
    Duration? lockTimeout,
  }) async {
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

    Result<T> userResult;
    try {
      userResult = await action(txnId);
    } on Object catch (e, st) {
      await _safelyRollback(connectionId, txnId);
      return Failure(
        QueryError(
          message: 'runInTransaction: action threw ${e.runtimeType}: $e\n$st',
        ),
      );
    }

    if (userResult.isError()) {
      await _safelyRollback(connectionId, txnId);
      return userResult;
    }

    final commitResult = await commitTransaction(connectionId, txnId);
    if (commitResult.isError()) {
      return Failure(commitResult.exceptionOrNull()!);
    }
    return userResult;
  }

  Future<Result<T>> runInXaTransaction<T extends Object>(
    String connectionId,
    Xid xid,
    Future<Result<T>> Function(XaTransactionHandle xa) action, {
    bool onePhase = false,
  }) async {
    final startResult = await _repository.xaStart(connectionId, xid);
    if (startResult.isError()) {
      return Failure(startResult.exceptionOrNull()!);
    }
    final xa = startResult.getOrNull()!;

    if (onePhase) {
      try {
        final userResult = await action(xa);
        if (userResult.isError()) {
          await _xaSafelyAbort(xa);
          return userResult;
        }
        if (!xa.commitOnePhase()) {
          await _xaSafelyAbort(xa);
          return Failure(
            QueryError(
              message: 'runInXaTransaction: xa_commit_one_phase failed '
                  'on xid=${xa.xid}',
            ),
          );
        }
        return userResult;
      } on Object catch (e, st) {
        await _xaSafelyAbort(xa);
        return Failure(
          QueryError(
            message: 'runInXaTransaction: action threw ${e.runtimeType}: '
                '$e\n$st',
          ),
        );
      }
    }

    try {
      final userResult = await action(xa);
      if (userResult.isError()) {
        await _xaSafelyAbort(xa);
        return userResult;
      }
      if (!xa.end()) {
        await _xaSafelyAbort(xa);
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_end failed on xid=${xa.xid}',
          ),
        );
      }
      if (!xa.prepare()) {
        await _xaSafelyAbort(xa);
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_prepare failed on xid=${xa.xid}',
          ),
        );
      }
      if (!xa.commitPrepared()) {
        await _xaSafelyAbort(xa);
        return Failure(
          QueryError(
            message: 'runInXaTransaction: xa_commit_prepared failed '
                'on xid=${xa.xid}',
          ),
        );
      }
      return userResult;
    } on Object catch (e, st) {
      await _xaSafelyAbort(xa);
      return Failure(
        QueryError(
          message: 'runInXaTransaction: action threw ${e.runtimeType}: '
              '$e\n$st',
        ),
      );
    }
  }

  Future<Result<void>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _repository.createSavepoint(connectionId, txnId, name);

  Future<Result<void>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _repository.rollbackToSavepoint(connectionId, txnId, name);

  Future<Result<void>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _repository.releaseSavepoint(connectionId, txnId, name);

  Future<void> _xaSafelyAbort(XaTransactionHandle xa) async {
    try {
      if (xa.state == XaState.active) {
        xa.end();
      }
      if (xa.state == XaState.prepared ||
          xa.state == XaState.failedAfterPrepare) {
        xa.rollbackPrepared();
      } else if (xa.state == XaState.idle || xa.state == XaState.failed) {
        xa.rollback();
      }
    } on Object catch (_) {
      // Best-effort cleanup; original error wins.
    }
  }

  Future<void> _safelyRollback(String connectionId, int txnId) async {
    try {
      await rollbackTransaction(connectionId, txnId);
    } on Object catch (_) {
      // Defensive: rollback failures are logged by the repository.
    }
  }
}
