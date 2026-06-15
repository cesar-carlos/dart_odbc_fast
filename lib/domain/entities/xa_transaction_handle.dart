import 'dart:developer' as developer;

import 'package:odbc_fast/domain/entities/xid.dart';

/// Native XA operations used by [XaTransactionHandle].
abstract interface class XaTransactionBackend {
  int xaEnd(int xaId);
  int xaPrepare(int xaId);
  int xaCommitPrepared(int xaId);
  int xaRollbackPrepared(int xaId);
  int xaCommitOnePhase(int xaId);
  int xaRollbackActive(int xaId);
}

/// Lifecycle states of an XA transaction branch — mirror of
/// `engine::xa_transaction::XaState` (Rust).
enum XaState {
  none,
  active,
  idle,
  prepared,
  committed,
  rolledBack,
  failed,
  failedAfterPrepare,
}

/// Lightweight wrapper around a native XA transaction id.
class XaTransactionHandle {
  XaTransactionHandle.withBackend({
    required this.xaId,
    required this.xid,
    required XaTransactionBackend backend,
    XaState initialState = XaState.active,
  })  : _backend = backend,
        _state = initialState;

  final int xaId;
  final Xid xid;

  final XaTransactionBackend _backend;
  XaState _state;

  XaState get state => _state;

  bool end() {
    final rc = _backend.xaEnd(xaId);
    if (rc == 0) {
      _state = XaState.idle;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  bool prepare() {
    final rc = _backend.xaPrepare(xaId);
    if (rc == 0) {
      _state = XaState.prepared;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  bool commitPrepared() {
    final rc = _backend.xaCommitPrepared(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failedAfterPrepare;
    return false;
  }

  bool rollbackPrepared() {
    final rc = _backend.xaRollbackPrepared(xaId);
    if (rc == 0) {
      _state = XaState.rolledBack;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  bool commitOnePhase() {
    final rc = _backend.xaCommitOnePhase(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  bool rollback() {
    final rc = _backend.xaRollbackActive(xaId);
    if (rc == 0) {
      _state = XaState.rolledBack;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

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
      } on Object catch (cleanupError, cleanupSt) {
        developer.log(
          'XA cleanup failed after operation error on xid=${xa.xid}',
          name: 'odbc_fast.xa',
          error: cleanupError,
          stackTrace: cleanupSt,
          level: 900,
        );
      }
      rethrow;
    }
  }

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
      } on Object catch (cleanupError, cleanupSt) {
        developer.log(
          'XA one-phase cleanup failed after operation error on xid=${xa.xid}',
          name: 'odbc_fast.xa',
          error: cleanupError,
          stackTrace: cleanupSt,
          level: 900,
        );
      }
      rethrow;
    }
  }
}
