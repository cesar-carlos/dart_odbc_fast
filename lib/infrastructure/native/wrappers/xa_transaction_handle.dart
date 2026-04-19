import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

/// Lifecycle states of an XA transaction branch — mirror of
/// `engine::xa_transaction::XaState` (Rust).
///
/// Sprint 4.3.
enum XaState {
  /// Returned only by [XaTransactionHandle.state] *after* a terminal
  /// transition; never observed on a live handle.
  none,

  /// `xa_start` succeeded; SQL on the underlying connection now joins
  /// the branch. Caller can run DML/DDL or jump straight to
  /// [XaTransactionHandle.commitOnePhase] / [XaTransactionHandle.rollback].
  active,

  /// `xa_end` succeeded; the branch is detached from the connection
  /// and ready to [XaTransactionHandle.prepare]. Cannot run further
  /// SQL on the branch.
  idle,

  /// `xa_prepare` succeeded; the branch is heuristically committable.
  /// The Transaction Manager decides Phase 2 via
  /// [XaTransactionHandle.commitPrepared] /
  /// [XaTransactionHandle.rollbackPrepared].
  prepared,

  /// `xa_commit_prepared` (or `xa_commit_one_phase`) succeeded.
  committed,

  /// Any rollback path completed.
  rolledBack,

  /// A non-recoverable failure left the branch in an undefined state.
  /// Recovery via [NativeOdbcConnection.xaRecover] +
  /// [NativeOdbcConnection.xaResumePrepared] is the only way out.
  failed,
}

/// Lightweight Dart wrapper around a native XA transaction id.
///
/// Constructed by [NativeOdbcConnection.xaStart] and the recovery
/// helpers; mirrors the Rust state machine documented in
/// `engine::xa_transaction`. The handle is thin on purpose — the
/// per-state contracts are enforced by the engine, not duplicated
/// here.
///
/// Sprint 4.3.
class XaTransactionHandle {
  /// Internal — built by [NativeOdbcConnection.xaStart] and friends.
  XaTransactionHandle({
    required this.xaId,
    required this.xid,
    required NativeOdbcConnection conn,
    XaState initialState = XaState.active,
  }) : _conn = conn,
       _state = initialState;

  /// Native XA branch id (>0). Pass to the lower-level
  /// `OdbcNative.xa*` methods if you need direct FFI access.
  final int xaId;

  /// XID this branch was opened with (or recovered as).
  final Xid xid;

  final NativeOdbcConnection _conn;
  XaState _state;

  /// Current state of the branch as observed by Dart. Engine-side the
  /// state may have advanced (e.g. crash recovery) — this getter is a
  /// best-effort cache; for crash-recovery flows query the engine via
  /// [NativeOdbcConnection.xaRecover] instead.
  XaState get state => _state;

  /// `xa_end`: detach the branch from the connection. Returns `true`
  /// on success. After success the state advances to [XaState.idle]
  /// and the caller must invoke [prepare] (Phase 1 of 2PC) or
  /// [rollback].
  bool end() {
    final rc = _conn.native.xaEnd(xaId);
    if (rc == 0) {
      _state = XaState.idle;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  /// `xa_prepare`: Phase 1 of 2PC. Promotes the branch from `Idle` to
  /// `Prepared`. Returns `true` on success.
  bool prepare() {
    final rc = _conn.native.xaPrepare(xaId);
    if (rc == 0) {
      _state = XaState.prepared;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  /// `xa_commit` (Phase 2): finalise a prepared branch.
  bool commitPrepared() {
    final rc = _conn.native.xaCommitPrepared(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  /// `xa_rollback` (Phase 2): roll back a prepared branch.
  bool rollbackPrepared() {
    final rc = _conn.native.xaRollbackPrepared(xaId);
    if (rc == 0) {
      _state = XaState.rolledBack;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  /// 1RM optimisation: fuse `prepare → commit` on an Active branch.
  /// **Only safe when this RM is the sole participant** in the global
  /// transaction.
  bool commitOnePhase() {
    final rc = _conn.native.xaCommitOnePhase(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  /// Roll back an Active branch (no PREPARE issued). The branch is
  /// gone after this call — there is no recovery path because no
  /// prepare-log entry exists.
  bool rollback() {
    final rc = _conn.native.xaRollbackActive(xaId);
    if (rc == 0) {
      _state = XaState.rolledBack;
      return true;
    }
    _state = XaState.failed;
    return false;
  }
}
