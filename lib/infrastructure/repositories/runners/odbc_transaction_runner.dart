import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/wrappers/xa_transaction_handle.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Transaction, savepoint, and XA / 2PC operations.
class OdbcTransactionRunner {
  OdbcTransactionRunner({
    required this.ffi,
    required this.state,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;

  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel, {
    SavepointDialect savepointDialect = SavepointDialect.auto,
    TransactionAccessMode accessMode = TransactionAccessMode.readWrite,
    Duration? lockTimeout,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (state.hasTransaction(connectionId)) {
      return const Failure(
        ValidationError(
          message: 'A transaction is already active on this connection',
        ),
      );
    }
    final lockTimeoutMs = lockTimeout == null
        ? 0
        : (lockTimeout.inMilliseconds == 0 && lockTimeout > Duration.zero
            ? 1
            : lockTimeout.inMilliseconds.clamp(0, 0xFFFFFFFF));
    try {
      final txnId = ffi.isAsync
          ? await ffi.async.beginTransaction(
              nativeId,
              isolationLevel.value,
              savepointDialect: savepointDialect.code,
              accessMode: accessMode.code,
              lockTimeoutMs: lockTimeoutMs,
            )
          : ffi.sync.beginTransaction(
              nativeId,
              isolationLevel.value,
              savepointDialect: savepointDialect.code,
              accessMode: accessMode.code,
              lockTimeoutMs: lockTimeoutMs,
            );

      if (txnId == 0) {
        return await ffi.convertNativeErrorToFailure<int>(
          errorFactory: odbcQueryErrorFactory,
          fallbackMessage: 'Failed to begin transaction',
        );
      }
      state.transactionOwners[txnId] = connectionId;
      return Success(txnId);
    } on OdbcError catch (e) {
      return Failure<int, OdbcError>(e);
    } on Exception catch (e, st) {
      return Failure<int, OdbcError>(
        translateOdbcError(e, operation: 'beginTransaction', stackTrace: st),
      );
    }
  }

  Future<Result<Unit>> commitTransaction(String connectionId, int txnId) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0 || state.transactionOwners[txnId] != connectionId) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    int? status;
    final result = await ffi.runBoolFfi(
      sync: (n) {
        status = n.commitTransactionStatus(txnId);
        return status == 0;
      },
      async: (a) async {
        final ok = await a.commitTransaction(txnId);
        status = NativeCallContext.current?.completionStatus ?? (ok ? 0 : 1);
        return ok;
      },
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: 'Failed to commit transaction',
      nativeConnectionId: nativeId,
    );
    if (status != null && status != 2) state.transactionOwners.remove(txnId);
    final error = result.exceptionOrNull();
    if (error is OdbcError) {
      return Failure(
        error.withDetails(
          error.details.copyWith(
            code: OdbcErrorCode.transaction,
            outcomeUnknown: status != 2,
          ),
        ),
      );
    }
    return result;
  }

  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0 || state.transactionOwners[txnId] != connectionId) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    int? status;
    final result = await ffi.runBoolFfi(
      sync: (n) {
        status = n.rollbackTransactionStatus(txnId);
        return status == 0;
      },
      async: (a) async {
        final ok = await a.rollbackTransaction(txnId);
        status = NativeCallContext.current?.completionStatus ?? (ok ? 0 : 1);
        return ok;
      },
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: 'Failed to rollback transaction',
      nativeConnectionId: nativeId,
    );
    if (status != null && status != 2) state.transactionOwners.remove(txnId);
    final error = result.exceptionOrNull();
    if (error is OdbcError) {
      return Failure(
        error.withDetails(
          error.details.copyWith(
            code: OdbcErrorCode.transaction,
            outcomeUnknown: status != 2,
          ),
        ),
      );
    }
    return result;
  }

  Future<Result<XaTransactionHandle>> xaStart(
    String connectionId,
    Xid xid,
  ) async {
    try {
      if (!state.connectionIds.containsKey(connectionId)) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(message: 'Invalid connection ID'),
        );
      }
      final cid = state.connectionIds[connectionId]!;
      if (ffi.isAsync) {
        final asyncConn = ffi.async;
        final xaId = await asyncConn.xaStart(cid, xid);
        if (xaId == 0) {
          return await ffi.convertNativeErrorToFailure<XaTransactionHandle>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'xa_start failed (null handle)',
            nativeConnectionId: cid,
          );
        }
        final handle = createAsyncXaTransactionHandle(
          xaId: xaId,
          xid: xid,
          conn: asyncConn,
        );
        state.registerXa(connectionId, handle);
        return Success(handle);
      }
      final native = ffi.sync;
      if (!native.supportsXa) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(
            message: 'The loaded native library does not export the XA FFI '
                'entry points',
          ),
        );
      }
      final h = native.xaStart(cid, xid);
      if (h == null) {
        final structured = native.getStructuredErrorForConnection(cid);
        if (structured != null) {
          return Failure<XaTransactionHandle, OdbcError>(
            QueryError(
              message: structured.message,
              sqlState: structured.sqlStateString,
              nativeCode: structured.nativeCode,
            ),
          );
        }
        final msg = native.getError();
        return Failure<XaTransactionHandle, OdbcError>(
          QueryError(
            message: msg.isNotEmpty ? msg : 'xa_start failed (null handle)',
          ),
        );
      }
      state.registerXa(connectionId, h);
      return Success(h);
    } on Exception catch (e, st) {
      return Failure<XaTransactionHandle, OdbcError>(
        translateOdbcError(e, operation: 'xaStart', stackTrace: st),
      );
    }
  }

  Future<Result<List<Xid>>> xaRecover(String connectionId) async {
    try {
      if (!state.connectionIds.containsKey(connectionId)) {
        return const Failure<List<Xid>, OdbcError>(
          ValidationError(message: 'Invalid connection ID'),
        );
      }
      final cid = state.connectionIds[connectionId]!;
      if (ffi.isAsync) {
        final recovered = await ffi.async.xaRecover(cid);
        if (recovered == null) {
          return await ffi.convertNativeErrorToFailure<List<Xid>>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'xa_recover failed',
            nativeConnectionId: cid,
          );
        }
        return Success(recovered);
      }
      final native = ffi.sync;
      if (!native.supportsXa) {
        return const Failure<List<Xid>, OdbcError>(
          ValidationError(
            message: 'The loaded native library does not export the XA FFI '
                'entry points',
          ),
        );
      }
      final recovered = native.xaRecover(cid);
      if (recovered == null) {
        return await ffi.convertNativeErrorToFailure<List<Xid>>(
          errorFactory: odbcQueryErrorFactory,
          fallbackMessage: 'xa_recover failed',
          nativeConnectionId: cid,
        );
      }
      return Success(recovered);
    } on Exception catch (e, st) {
      return Failure<List<Xid>, OdbcError>(
        translateOdbcError(e, operation: 'xaRecover', stackTrace: st),
      );
    }
  }

  Future<Result<XaTransactionHandle>> xaResumePrepared(
    String connectionId,
    Xid xid,
  ) async {
    try {
      if (!state.connectionIds.containsKey(connectionId)) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(message: 'Invalid connection ID'),
        );
      }
      final cid = state.connectionIds[connectionId]!;
      if (ffi.isAsync) {
        final asyncConn = ffi.async;
        final xaId = await asyncConn.xaResumePrepared(cid, xid);
        if (xaId == 0) {
          return await ffi.convertNativeErrorToFailure<XaTransactionHandle>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'xa_resume_prepared failed',
            nativeConnectionId: cid,
          );
        }
        final handle = createAsyncXaTransactionHandle(
          xaId: xaId,
          xid: xid,
          conn: asyncConn,
          initialState: XaState.prepared,
        );
        state.registerXa(connectionId, handle);
        return Success(handle);
      }
      final native = ffi.sync;
      if (!native.supportsXa) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(
            message: 'The loaded native library does not export the XA FFI '
                'entry points',
          ),
        );
      }
      final h = native.xaResumePrepared(cid, xid);
      if (h == null) {
        return await ffi.convertNativeErrorToFailure<XaTransactionHandle>(
          errorFactory: odbcQueryErrorFactory,
          fallbackMessage: 'xa_resume_prepared failed',
          nativeConnectionId: cid,
        );
      }
      state.registerXa(connectionId, h);
      return Success(h);
    } on Exception catch (e, st) {
      return Failure<XaTransactionHandle, OdbcError>(
        translateOdbcError(e, operation: 'xaResumePrepared', stackTrace: st),
      );
    }
  }

  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _savepoint(
        connectionId: connectionId,
        txnId: txnId,
        name: name,
        sync: (n) => n.createSavepoint(txnId, name),
        async: (a) => a.createSavepoint(txnId, name),
        fallbackMessage: 'Failed to create savepoint',
      );

  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _savepoint(
        connectionId: connectionId,
        txnId: txnId,
        name: name,
        sync: (n) => n.rollbackToSavepoint(txnId, name),
        async: (a) => a.rollbackToSavepoint(txnId, name),
        fallbackMessage: 'Failed to rollback to savepoint',
      );

  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) =>
      _savepoint(
        connectionId: connectionId,
        txnId: txnId,
        name: name,
        sync: (n) => n.releaseSavepoint(txnId, name),
        async: (a) => a.releaseSavepoint(txnId, name),
        fallbackMessage: 'Failed to release savepoint',
      );

  Future<Result<Unit>> _savepoint({
    required String connectionId,
    required int txnId,
    required String name,
    required bool Function(NativeOdbcConnection n) sync,
    required Future<bool> Function(AsyncNativeOdbcConnection a) async,
    required String fallbackMessage,
  }) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    if (txnId <= 0 || state.transactionOwners[txnId] != connectionId) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    if (name.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Savepoint name cannot be empty'),
      );
    }
    return ffi.runBoolFfi(
      sync: sync,
      async: async,
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: fallbackMessage,
      nativeConnectionId: nativeId,
    );
  }
}
