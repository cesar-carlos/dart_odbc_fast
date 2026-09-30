import 'dart:async';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';

/// Native XA operations used by [XaTransactionHandle].
///
/// Sync backends may complete with [Future.value]; async isolate backends
/// return real futures that hop to the worker owning the XA branch.
abstract interface class XaTransactionBackend {
  Future<int> xaEnd(int xaId);
  Future<int> xaPrepare(int xaId);
  Future<int> xaCommitPrepared(int xaId);
  Future<int> xaRollbackPrepared(int xaId);
  Future<int> xaCommitOnePhase(int xaId);
  Future<int> xaRollbackActive(int xaId);
}

/// Optional diagnostics supplied by native XA backend adapters.
abstract interface class XaDiagnosticBackend {
  OdbcError? get lastError;
  void clearDiagnostic();
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
  OdbcError? get lastError => _backend is XaDiagnosticBackend
      ? (_backend as XaDiagnosticBackend).lastError
      : null;

  Future<bool> end() async {
    final rc = await _backend.xaEnd(xaId);
    if (rc == 0) {
      _state = XaState.idle;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  Future<bool> prepare() async {
    final rc = await _backend.xaPrepare(xaId);
    if (rc == 0) {
      _state = XaState.prepared;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  Future<bool> commitPrepared() async {
    final rc = await _backend.xaCommitPrepared(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failedAfterPrepare;
    return false;
  }

  Future<bool> rollbackPrepared() async {
    final rc = await _backend.xaRollbackPrepared(xaId);
    if (rc == 0) {
      _state = XaState.rolledBack;
      return true;
    }
    _state = XaState.failedAfterPrepare;
    return false;
  }

  Future<bool> commitOnePhase() async {
    final rc = await _backend.xaCommitOnePhase(xaId);
    if (rc == 0) {
      _state = XaState.committed;
      return true;
    }
    _state = XaState.failed;
    return false;
  }

  Future<bool> rollback() async {
    final rc = await _backend.xaRollbackActive(xaId);
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
    var committing = false;
    try {
      final result = await action(xa);
      if (!await xa.end()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_end failed on xid=${xa.xid}',
        );
      }
      if (!await xa.prepare()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_prepare failed '
          'on xid=${xa.xid}',
        );
      }
      committing = true;
      if (!await xa.commitPrepared()) {
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_commit_prepared failed '
          'on xid=${xa.xid}',
        );
      }
      return result;
    } on Object catch (error, stack) {
      if (committing || xa.state == XaState.failedAfterPrepare) rethrow;
      final cleanup = await _cleanup(xa, error, stack);
      if (cleanup != null) Error.throwWithStackTrace(cleanup, stack);
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
    var committing = false;
    try {
      final result = await action(xa);
      committing = true;
      if (!await xa.commitOnePhase()) {
        throw StateError(
          'XaTransactionHandle.runWithStartOnePhase: xa_commit_one_phase '
          'failed on xid=${xa.xid}',
        );
      }
      return result;
    } on Object catch (error, stack) {
      if (committing || xa.state == XaState.failedAfterPrepare) rethrow;
      final cleanup = await _cleanup(xa, error, stack);
      if (cleanup != null) Error.throwWithStackTrace(cleanup, stack);
      rethrow;
    }
  }

  static Future<OdbcError?> _cleanup(
    XaTransactionHandle xa,
    Object error,
    StackTrace stack,
  ) async {
    OdbcError? combined;
    void secondary(OdbcError failure) {
      combined = (combined ??
              normalizeOdbcError(
                error,
                operation: 'xaTransaction',
                stackTrace: stack,
              ))
          .withSecondary(failure);
    }

    if (xa.state == XaState.active) {
      try {
        if (!await xa.end()) {
          secondary(
            const QueryError(
              message: 'XA end failed during cleanup',
              details: OdbcErrorDetails(
                code: OdbcErrorCode.cleanup,
                operation: 'xaEnd',
              ),
            ),
          );
        }
      } on Object catch (failure, trace) {
        secondary(
          normalizeOdbcError(failure, operation: 'xaEnd', stackTrace: trace),
        );
      }
    }
    try {
      final ok = xa.state == XaState.prepared
          ? await xa.rollbackPrepared()
          : await xa.rollback();
      if (!ok) {
        secondary(
          const RollbackFailedError(
            message: 'XA rollback failed during cleanup',
          ),
        );
      }
    } on Object catch (failure, trace) {
      secondary(
        normalizeOdbcError(
          failure,
          operation: 'xaRollback',
          stackTrace: trace,
        ),
      );
    }
    return combined;
  }
}
