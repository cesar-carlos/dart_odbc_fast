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

  /// Runs [action] inside a fresh XA branch obtained from [startFn] and
  /// drives the full Two-Phase Commit lifecycle:
  ///
  /// On normal completion:
  ///   `xa_end` → `xa_prepare` → `xa_commit_prepared`
  ///
  /// On any thrown exception (or runtime error):
  ///   1. If the branch is still `Active`, emit `xa_end` to detach it
  ///      from the connection (without `end` the engine refuses
  ///      `xa_rollback`).
  ///   2. Roll back via `xa_rollback` (Active/Idle) or
  ///      `xa_rollback_prepared` (Prepared) depending on where the
  ///      throw landed in the lifecycle.
  ///   3. Rethrow so the caller sees the original cause.
  ///
  /// Mirrors the `TransactionHandle.runWithBegin` convention for local
  /// transactions and is the recommended way to drive a 2PC branch
  /// from Dart without leaking branches on early returns / exceptions.
  ///
  /// `startFn` is whatever piece of API returns a `XaTransactionHandle?`
  /// (typically `() => native.xaStart(connId, xid)`). When it returns
  /// `null` (the underlying `xa_start` failed) the helper throws
  /// `StateError` with the stock diagnostic so the caller can surface
  /// `native.getError()` if they need a richer message.
  ///
  /// Engine notes:
  ///
  /// - On Oracle, when [action] runs no DML the engine returns
  ///   `XA_RDONLY=3` from `xa_prepare` and silently auto-completes
  ///   the branch. The [Rust apply_xa_prepare] tolerates this rc as
  ///   success and the follow-up `xa_commit_prepared` tolerates the
  ///   resulting `XAER_NOTA=-4` as a no-op, so the helper completes
  ///   normally even for read-only branches. PG / MySQL / MariaDB /
  ///   DB2 always log a prepare entry, regardless of DML.
  /// - Returns `T` directly (not `Result<T>`) so it composes with both
  ///   `try/catch` and `on Object catch (e, st)` styles. Rollback
  ///   failures are swallowed by design — they would obscure the
  ///   original throw — but the underlying engine logs them via the
  ///   structured-error channel.
  ///
  /// Example:
  /// ```dart
  /// final result = await XaTransactionHandle.runWithStart<int>(
  ///   () => native.xaStart(connId, xid),
  ///   (xa) async {
  ///     final r = native.executeQueryParams(
  ///       connId, 'INSERT INTO logs(msg) VALUES (?)', ['hello'],
  ///     );
  ///     if (r == null) throw StateError('insert failed');
  ///     return 42;
  ///   },
  /// );
  /// ```
  static Future<T> runWithStart<T>(
    XaTransactionHandle? Function() startFn,
    Future<T> Function(XaTransactionHandle xa) action,
  ) async {
    final xa = startFn();
    if (xa == null) {
      throw StateError(
        'XaTransactionHandle.runWithStart: xa_start returned null '
        '(check native.getError() for the underlying ODBC diagnostic).',
      );
    }
    try {
      final result = await action(xa);
      // Happy path: end → prepare → commit_prepared. Each step is
      // checked because a silent failure would leave the branch
      // dangling (or, worse, half-committed across RMs).
      if (!xa.end()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_end failed on xid=${xa.xid}',
        );
      }
      if (!xa.prepare()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_prepare failed '
          'on xid=${xa.xid}',
        );
      }
      if (!xa.commitPrepared()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_commit_prepared failed '
          'on xid=${xa.xid}',
        );
      }
      return result;
    } on Object {
      // Best-effort rollback: emit xa_end if still attached, then
      // rollback via the path appropriate for the branch's current
      // state. Failures here are intentionally swallowed — they
      // would mask the original throw — but the engine logs them
      // through the structured-error channel.
      try {
        if (xa.state == XaState.active) {
          xa.end(); // advances to idle (or failed)
        }
        if (xa.state == XaState.prepared) {
          xa.rollbackPrepared();
        } else if (xa.state == XaState.idle || xa.state == XaState.failed) {
          xa.rollback();
        }
      } on Object catch (_) {
        // Defensive: nothing useful to do from here.
      }
      rethrow;
    }
  }

  /// 1RM-optimised variant of [runWithStart]: fuses `xa_prepare` and
  /// `xa_commit` into a single `xa_commit_one_phase` call when this
  /// RM is the sole participant in the global transaction.
  ///
  /// **Only safe when no other Resource Manager has enlisted in the
  /// same global transaction** — a normal Transaction Manager will
  /// not pick this path; it's an explicit single-RM shortcut.
  ///
  /// Same exception-safety contract as [runWithStart]: thrown actions
  /// are rolled back via `xa_end` + `xa_rollback` and the original
  /// cause is rethrown.
  static Future<T> runWithStartOnePhase<T>(
    XaTransactionHandle? Function() startFn,
    Future<T> Function(XaTransactionHandle xa) action,
  ) async {
    final xa = startFn();
    if (xa == null) {
      throw StateError(
        'XaTransactionHandle.runWithStartOnePhase: xa_start returned null '
        '(check native.getError() for the underlying ODBC diagnostic).',
      );
    }
    try {
      final result = await action(xa);
      if (!xa.commitOnePhase()) {
        throw StateError(
          'XaTransactionHandle.runWithStartOnePhase: xa_commit_one_phase '
          'failed on xid=${xa.xid}',
        );
      }
      return result;
    } on Object {
      try {
        if (xa.state == XaState.active) {
          xa.end();
        }
        if (xa.state == XaState.idle || xa.state == XaState.failed) {
          xa.rollback();
        }
      } on Object catch (_) {
        // Defensive — see runWithStart.
      }
      rethrow;
    }
  }
}
