import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

export 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';

final class _NativeXaTransactionBackend implements XaTransactionBackend {
  const _NativeXaTransactionBackend(this._conn);

  final NativeOdbcConnection _conn;

  @override
  Future<int> xaEnd(int xaId) async => _conn.native.xaEnd(xaId);

  @override
  Future<int> xaPrepare(int xaId) async => _conn.native.xaPrepare(xaId);

  @override
  Future<int> xaCommitPrepared(int xaId) async =>
      _conn.native.xaCommitPrepared(xaId);

  @override
  Future<int> xaRollbackPrepared(int xaId) async =>
      _conn.native.xaRollbackPrepared(xaId);

  @override
  Future<int> xaCommitOnePhase(int xaId) async =>
      _conn.native.xaCommitOnePhase(xaId);

  @override
  Future<int> xaRollbackActive(int xaId) async =>
      _conn.native.xaRollbackActive(xaId);
}

final class _AsyncXaTransactionBackend implements XaTransactionBackend {
  const _AsyncXaTransactionBackend(this._conn);

  final AsyncNativeOdbcConnection _conn;

  @override
  Future<int> xaEnd(int xaId) => _conn.xaEnd(xaId);

  @override
  Future<int> xaPrepare(int xaId) => _conn.xaPrepare(xaId);

  @override
  Future<int> xaCommitPrepared(int xaId) => _conn.xaCommitPrepared(xaId);

  @override
  Future<int> xaRollbackPrepared(int xaId) => _conn.xaRollbackPrepared(xaId);

  @override
  Future<int> xaCommitOnePhase(int xaId) => _conn.xaCommitOnePhase(xaId);

  @override
  Future<int> xaRollbackActive(int xaId) => _conn.xaRollbackActive(xaId);
}

/// Builds a live [XaTransactionHandle] backed by [NativeOdbcConnection] FFI.
XaTransactionHandle createNativeXaTransactionHandle({
  required int xaId,
  required Xid xid,
  required NativeOdbcConnection conn,
  XaState initialState = XaState.active,
}) {
  return XaTransactionHandle.withBackend(
    xaId: xaId,
    xid: xid,
    backend: _NativeXaTransactionBackend(conn),
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
