import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
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
        return ffi.convertNativeErrorToFailure<int>(
          errorFactory: odbcQueryErrorFactory,
          fallbackMessage: 'Failed to begin transaction',
        );
      }
      return Success(txnId);
    } on Exception catch (e) {
      return Failure<int, OdbcError>(
        QueryError(message: e.toString()),
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
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    return ffi.runBoolFfi(
      sync: (n) => n.commitTransaction(txnId),
      async: (a) => a.commitTransaction(txnId),
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: 'Failed to commit transaction',
      nativeConnectionId: nativeId,
    );
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
    if (txnId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid transaction ID'),
      );
    }
    return ffi.runBoolFfi(
      sync: (n) => n.rollbackTransaction(txnId),
      async: (a) => a.rollbackTransaction(txnId),
      errorFactory: odbcQueryErrorFactory,
      fallbackMessage: 'Failed to rollback transaction',
      nativeConnectionId: nativeId,
    );
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
      if (ffi.isAsync) {
        return const Failure<XaTransactionHandle, OdbcError>(
          ValidationError(
            message:
                'XA / 2PC is not supported on the async ODBC repository backend',
          ),
        );
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
      final cid = state.connectionIds[connectionId]!;
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
      return Success(h);
    } on Exception catch (e) {
      return Failure<XaTransactionHandle, OdbcError>(
        QueryError(message: e.toString()),
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
    if (txnId <= 0) {
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
