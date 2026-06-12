import 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

export 'package:odbc_fast/domain/entities/xa_transaction_handle.dart';

final class _NativeXaTransactionBackend implements XaTransactionBackend {
  const _NativeXaTransactionBackend(this._conn);

  final NativeOdbcConnection _conn;

  @override
  int xaEnd(int xaId) => _conn.native.xaEnd(xaId);

  @override
  int xaPrepare(int xaId) => _conn.native.xaPrepare(xaId);

  @override
  int xaCommitPrepared(int xaId) => _conn.native.xaCommitPrepared(xaId);

  @override
  int xaRollbackPrepared(int xaId) => _conn.native.xaRollbackPrepared(xaId);

  @override
  int xaCommitOnePhase(int xaId) => _conn.native.xaCommitOnePhase(xaId);

  @override
  int xaRollbackActive(int xaId) => _conn.native.xaRollbackActive(xaId);
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
