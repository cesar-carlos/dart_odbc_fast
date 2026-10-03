import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_execution_stage.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

export 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';

final class _NativeXaTransactionBackend
    implements XaTransactionBackend, XaDiagnosticBackend, XaExecutionBackend {
  _NativeXaTransactionBackend(this._conn, this._connectionId);
  final int? _connectionId;
  OdbcError? _error;
  @override
  bool lastCallNotStarted = false;
  @override
  void registerReconciliation(void Function(String, int?) callback) {}
  @override
  OdbcError? get lastError => _error;
  @override
  void clearDiagnostic() {
    _error = null;
  }

  int _run(String operation, int Function() call) {
    clearDiagnostic();
    lastCallNotStarted = false;
    final int rc;
    try {
      rc = NativeCallContext.invoke(call);
    } on Object catch (cause, stack) {
      _error = translateOdbcError(
        cause,
        operation: operation,
        stackTrace: stack,
      );
      rethrow;
    }
    if (rc == 0) return rc;
    _error = QueryError(
      message: 'The XA phase failed',
      details: OdbcErrorDetails(
        operation: operation,
        code: OdbcErrorCode.transaction,
      ),
    );
    try {
      final diagnostic = _connectionId == null
          ? _conn.getStructuredError()
          : _conn.getStructuredErrorForConnection(_connectionId);
      if (diagnostic != null) {
        _error = QueryError(
          message: diagnostic.message,
          sqlState: diagnostic.sqlStateString,
          nativeCode: diagnostic.nativeCode,
          details: _error!.details,
        );
      }
    } on Object catch (error, stack) {
      _error = _error!.withSecondary(
        translateOdbcError(
          error,
          operation: 'collectDiagnostic',
          stackTrace: stack,
        ),
      );
    }
    return rc;
  }

  final NativeOdbcConnection _conn;

  @override
  Future<int> xaEnd(int xaId) async =>
      _run('xaEnd', () => _conn.native.xaEnd(xaId));

  @override
  Future<int> xaPrepare(int xaId) async =>
      _run('xaPrepare', () => _conn.native.xaPrepare(xaId));

  @override
  Future<int> xaCommitPrepared(int xaId) async =>
      _run('xaCommitPrepared', () => _conn.native.xaCommitPrepared(xaId));

  @override
  Future<int> xaRollbackPrepared(int xaId) async =>
      _run('xaRollbackPrepared', () => _conn.native.xaRollbackPrepared(xaId));

  @override
  Future<int> xaCommitOnePhase(int xaId) async =>
      _run('xaCommitOnePhase', () => _conn.native.xaCommitOnePhase(xaId));

  @override
  Future<int> xaRollbackActive(int xaId) async =>
      _run('xaRollbackActive', () => _conn.native.xaRollbackActive(xaId));
}

final class _AsyncXaTransactionBackend
    implements XaTransactionBackend, XaDiagnosticBackend, XaExecutionBackend {
  _AsyncXaTransactionBackend(this._conn);
  OdbcError? _error;
  @override
  bool lastCallNotStarted = false;
  void Function(String, int?)? _reconciled;
  @override
  void registerReconciliation(void Function(String, int?) callback) {
    _reconciled = callback;
  }

  @override
  OdbcError? get lastError => _error;
  @override
  void clearDiagnostic() {
    _error = null;
  }

  Future<int> _run(String operation, Future<int> Function() call) =>
      NativeCallContext.capture(() async {
        _error = null;
        lastCallNotStarted = false;
        final context = NativeCallContext.current!
          ..onReconciled = (status) => _reconciled?.call(operation, status);
        int rc;
        try {
          rc = await call();
          lastCallNotStarted =
              context.executionStage == NativeExecutionStage.notStarted;
        } on Object catch (cause, stack) {
          lastCallNotStarted =
              context.executionStage == NativeExecutionStage.notStarted;
          _error = translateOdbcError(
            cause,
            operation: operation,
            stackTrace: stack,
          );
          rethrow;
        }
        if (rc != 0) {
          _error = NativeCallContext.takeFailure() ??
              QueryError(
                message: 'The XA phase failed',
                details: OdbcErrorDetails(
                  operation: operation,
                  code: OdbcErrorCode.transaction,
                ),
              );
        }
        return rc;
      });

  final AsyncNativeOdbcConnection _conn;

  @override
  Future<int> xaEnd(int xaId) => _run('xaEnd', () => _conn.xaEnd(xaId));

  @override
  Future<int> xaPrepare(int xaId) =>
      _run('xaPrepare', () => _conn.xaPrepare(xaId));

  @override
  Future<int> xaCommitPrepared(int xaId) =>
      _run('xaCommitPrepared', () => _conn.xaCommitPrepared(xaId));

  @override
  Future<int> xaRollbackPrepared(int xaId) =>
      _run('xaRollbackPrepared', () => _conn.xaRollbackPrepared(xaId));

  @override
  Future<int> xaCommitOnePhase(int xaId) =>
      _run('xaCommitOnePhase', () => _conn.xaCommitOnePhase(xaId));

  @override
  Future<int> xaRollbackActive(int xaId) =>
      _run('xaRollbackActive', () => _conn.xaRollbackActive(xaId));
}

/// Builds a live [XaTransactionHandle] backed by [NativeOdbcConnection] FFI.
XaTransactionHandle createNativeXaTransactionHandle({
  required int xaId,
  required Xid xid,
  required NativeOdbcConnection conn,
  int? connectionId,
  XaState initialState = XaState.active,
}) {
  return XaTransactionHandle.withBackend(
    xaId: xaId,
    xid: xid,
    backend: _NativeXaTransactionBackend(conn, connectionId),
    initialState: initialState,
  );
}

/// Builds a live [XaTransactionHandle] backed by the async isolate worker.
XaTransactionHandle createAsyncXaTransactionHandle({
  required int xaId,
  required Xid xid,
  required AsyncNativeOdbcConnection conn,
  XaState initialState = XaState.active,
}) {
  return XaTransactionHandle.withBackend(
    xaId: xaId,
    xid: xid,
    backend: _AsyncXaTransactionBackend(conn),
    initialState: initialState,
  );
}
