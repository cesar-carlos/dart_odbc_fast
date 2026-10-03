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

/// Optional evidence and late completion notifications from an adapter.
abstract interface class XaExecutionBackend {
  bool get lastCallNotStarted;
  void registerReconciliation(
    void Function(String operation, int? status) callback,
  );
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
        _xidContext = xid.toString(),
        _state = initialState {
    if (backend is XaExecutionBackend) {
      (backend as XaExecutionBackend).registerReconciliation(_reconcile);
    }
  }

  final int xaId;
  final Xid xid;

  final XaTransactionBackend _backend;
  final String _xidContext;
  XaState _state;
  OdbcError? _lastError;
  bool _outcomeUnknown = false;
  bool _phaseInProgress = false;
  bool _commitAttempted = false;

  /// True when a phase may have executed without a confirmed outcome.
  bool get outcomeUnknown => _outcomeUnknown;

  /// Whether commit has been attempted, including a call rejected before FFI.
  /// Orchestration must not repeat that decision or automatically roll it back.
  bool get commitAttempted => _commitAttempted;

  XaState get state => _state;
  OdbcError? get lastError =>
      _lastError ??
      (_backend is XaDiagnosticBackend
          ? (_backend as XaDiagnosticBackend).lastError
          : null);

  Future<bool> _phase(
    String operation,
    Future<int> Function(int) invoke,
    XaState success,
    XaState failed, {
    bool committing = false,
  }) async {
    if (_phaseInProgress ||
        _outcomeUnknown ||
        _state == XaState.committed ||
        _state == XaState.rolledBack) {
      throw const ValidationError(
        message: 'The XA branch is not available for this operation',
      );
    }
    _phaseInProgress = true;
    _commitAttempted = _commitAttempted || committing;
    _lastError = null;
    final previous = _state;
    try {
      final rc = await invoke(xaId);
      if (rc == 0) {
        _state = success;
        return true;
      }
      final backendError = _backend is XaDiagnosticBackend
          ? (_backend as XaDiagnosticBackend).lastError
          : null;
      final notStarted = _backend is XaExecutionBackend &&
          (_backend as XaExecutionBackend).lastCallNotStarted;
      _outcomeUnknown = !notStarted &&
          (committing || (backendError?.details.outcomeUnknown ?? false));
      _state = notStarted
          ? previous
          : operation == 'xaPrepare' && !_outcomeUnknown
              ? XaState.failed
              : failed;
      _lastError = _decorate(
        backendError ??
            const QueryError(
              message: 'The XA transaction phase failed',
            ),
        operation,
      );
      return false;
    } on Object catch (error, stack) {
      final notStarted = _backend is XaExecutionBackend &&
          (_backend as XaExecutionBackend).lastCallNotStarted;
      _outcomeUnknown = !notStarted;
      _state = notStarted ? previous : failed;
      _lastError = _decorate(
        normalizeOdbcError(
          error,
          operation: operation,
          stackTrace: stack,
        ),
        operation,
      );
      rethrow;
    } finally {
      _phaseInProgress = false;
    }
  }

  OdbcError _decorate(OdbcError error, String operation) => error.withDetails(
        error.details.copyWith(
          operation: operation,
          transactionId: _xidContext,
          code: OdbcErrorCode.transaction,
          outcomeUnknown: _outcomeUnknown,
        ),
      );

  void _reconcile(String operation, int? status) {
    if (status != 0) return;
    _state = switch (operation) {
      'xaEnd' => XaState.idle,
      'xaPrepare' => XaState.prepared,
      'xaCommitPrepared' || 'xaCommitOnePhase' => XaState.committed,
      'xaRollbackPrepared' || 'xaRollbackActive' => XaState.rolledBack,
      _ => _state,
    };
    _outcomeUnknown = false;
    if (_lastError case final error?) {
      _lastError =
          error.withDetails(error.details.copyWith(outcomeUnknown: false));
    }
  }

  Future<bool> end() async {
    return _phase('xaEnd', _backend.xaEnd, XaState.idle, XaState.failed);
  }

  Future<bool> prepare() async {
    return _phase(
      'xaPrepare',
      _backend.xaPrepare,
      XaState.prepared,
      XaState.failedAfterPrepare,
    );
  }

  Future<bool> commitPrepared() async {
    return _phase(
      'xaCommitPrepared',
      _backend.xaCommitPrepared,
      XaState.committed,
      XaState.failedAfterPrepare,
      committing: true,
    );
  }

  Future<bool> rollbackPrepared() async {
    return _phase(
      'xaRollbackPrepared',
      _backend.xaRollbackPrepared,
      XaState.rolledBack,
      XaState.failedAfterPrepare,
    );
  }

  Future<bool> commitOnePhase() async {
    return _phase(
      'xaCommitOnePhase',
      _backend.xaCommitOnePhase,
      XaState.committed,
      XaState.failed,
      committing: true,
    );
  }

  Future<bool> rollback() async {
    return _phase(
      'xaRollbackActive',
      _backend.xaRollbackActive,
      XaState.rolledBack,
      XaState.failed,
    );
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
      if (xa.state == XaState.committed) return result;
      if (xa.state == XaState.rolledBack ||
          xa.outcomeUnknown ||
          xa._commitAttempted) {
        final error = xa.lastError;
        if (error != null) throw error;
        throw StateError('XA action already completed a phase');
      }
      if (xa.state == XaState.active && !await xa.end()) {
        if (xa.lastError case final error?) throw error;
        throw StateError('xa_end failed on xid=${xa.xid}');
      }
      if (xa.state == XaState.idle && !await xa.prepare()) {
        if (xa.lastError case final error?) throw error;
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_prepare failed '
          'on xid=${xa.xid}',
        );
      }
      if (xa.state != XaState.prepared) {
        if (xa.lastError case final error?) throw error;
        throw StateError('XA branch is not prepared');
      }
      committing = true;
      if (!await xa.commitPrepared()) {
        if (xa.lastError case final error?) throw error;
        throw StateError(
          'XaTransactionHandle.runWithStart: xa_commit_prepared failed '
          'on xid=${xa.xid}',
        );
      }
      return result;
    } on Object catch (error, stack) {
      if (committing ||
          xa._commitAttempted ||
          xa.outcomeUnknown ||
          xa.state == XaState.failedAfterPrepare ||
          xa.state == XaState.committed ||
          xa.state == XaState.rolledBack) {
        rethrow;
      }
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
      if (xa.state == XaState.committed) return result;
      if (xa.state == XaState.rolledBack ||
          xa.outcomeUnknown ||
          xa._commitAttempted) {
        final error = xa.lastError;
        if (error != null) throw error;
        throw StateError('XA action already completed a phase');
      }
      committing = true;
      if (!await xa.commitOnePhase()) {
        if (xa.lastError case final error?) throw error;
        throw StateError(
          'XaTransactionHandle.runWithStartOnePhase: xa_commit_one_phase '
          'failed on xid=${xa.xid}',
        );
      }
      return result;
    } on Object catch (error, stack) {
      if (committing ||
          xa._commitAttempted ||
          xa.outcomeUnknown ||
          xa.state == XaState.failedAfterPrepare ||
          xa.state == XaState.committed ||
          xa.state == XaState.rolledBack) {
        rethrow;
      }
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
