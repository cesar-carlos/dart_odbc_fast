import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

/// Convenience wrapper around an active transaction.
///
/// `TransactionHandle` owns the `txnId` returned by the native
/// `odbc_transaction_begin` call and exposes the full lifecycle (commit,
/// rollback, savepoints) on a single object.
///
/// Two safety nets were added in v3.1:
///
/// - [TransactionHandle.runWithBegin]: a static helper that runs a closure
///   inside a transaction, committing on success and rolling back on **any**
///   error or thrown exception. Use it instead of manual try/finally to make
///   leaks impossible.
/// - A best-effort native finalizer that fires when the Dart object is
///   garbage-collected without an explicit commit/rollback. The finalizer
///   reclaims the small native token allocated to track the transaction.
///   The transaction itself is rolled back by the engine when
///   `odbc_disconnect` runs (already implemented in
///   `ffi/mod.rs::odbc_disconnect` since v2.0).
///
/// Example:
/// ```dart
/// final result = await TransactionHandle.runWithBegin(
///   () => native.beginTransactionHandle(connId, isolationLevel.value),
///   (txn) async {
///     await txn.withSavepoint('sp_first', () async { /* ... */ });
///     return 'done';
///   },
/// );
/// ```
class TransactionHandle implements ffi.Finalizable {
  /// Creates a new [TransactionHandle] instance.
  ///
  /// `backend` must be a valid ODBC connection backend instance.
  /// `txnId` must be a non-zero transaction identifier returned by the
  /// native `odbc_transaction_begin` call.
  TransactionHandle(this._backend, this._txnId) : _state = _State.active {
    _attachFinalizer();
  }

  final OdbcConnectionBackend _backend;
  final int _txnId;
  _State _state;

  /// The transaction identifier returned by `odbc_transaction_begin`.
  int get txnId => _txnId;

  /// Whether this transaction has not yet been committed or rolled back.
  bool get isActive => _state == _State.active;

  /// Commits the transaction.
  ///
  /// Returns true on success, false on failure. After this call the
  /// transaction is no longer active and the finalizer will not fire.
  bool commit() {
    if (_state != _State.active) {
      return false;
    }
    final ok = _backend.commitTransaction(_txnId);
    _state = ok ? _State.committed : _State.failed;
    if (ok) _detachFinalizer();
    return ok;
  }

  /// Rolls back the transaction.
  ///
  /// Returns true on success, false on failure. After this call the
  /// transaction is no longer active and the finalizer will not fire.
  bool rollback() {
    if (_state != _State.active) {
      return false;
    }
    final ok = _backend.rollbackTransaction(_txnId);
    _state = ok ? _State.rolledBack : _State.failed;
    if (ok) _detachFinalizer();
    return ok;
  }

  /// Creates a savepoint named [name] inside this transaction.
  ///
  /// The savepoint name MUST match the identifier grammar enforced by the
  /// engine (ASCII letter or `_`, then letters/digits/`_`, ≤128 chars).
  /// Names containing semicolons, quotes or whitespace are rejected at the
  /// FFI boundary (B1 fix in v3.1).
  bool createSavepoint(String name) => _backend.createSavepoint(_txnId, name);

  /// Rolls back to the named savepoint. The transaction itself stays active.
  bool rollbackToSavepoint(String name) =>
      _backend.rollbackToSavepoint(_txnId, name);

  /// Releases the named savepoint (no-op on SQL Server). The transaction
  /// stays active.
  bool releaseSavepoint(String name) => _backend.releaseSavepoint(_txnId, name);

  /// Runs [action] within a savepoint named [name]. On success the savepoint
  /// is released; on any thrown exception we rollback to the savepoint, then
  /// rethrow so the caller can decide what to do with the surrounding
  /// transaction.
  ///
  /// This is the recommended way to do partial-rollback inside a longer
  /// transaction.
  Future<T> withSavepoint<T>(
    String name,
    Future<T> Function() action,
  ) async {
    if (!createSavepoint(name)) {
      throw StateError('Failed to create savepoint "$name" on txn $_txnId');
    }
    try {
      final result = await action();
      releaseSavepoint(name);
      return result;
    } on Object {
      rollbackToSavepoint(name);
      // We do not auto-release after rollback: SQL-92 keeps the savepoint
      // alive after ROLLBACK TO, and SQL Server has no RELEASE at all.
      rethrow;
    }
  }

  /// Runs [action] inside a fresh transaction obtained from [beginFn].
  ///
  /// On normal completion the transaction is committed; on any thrown
  /// exception (or runtime error) it is rolled back **before** rethrowing.
  /// This mirrors `Transaction::execute` on the Rust side and is the easiest
  /// way to write leak-proof Dart transaction code.
  ///
  /// `beginFn` is whatever piece of API returns a `TransactionHandle?` (e.g.
  /// `NativeOdbcConnection.beginTransactionHandle`).
  static Future<T> runWithBegin<T>(
    TransactionHandle? Function() beginFn,
    Future<T> Function(TransactionHandle txn) action,
  ) async {
    final txn = beginFn();
    if (txn == null) {
      throw StateError('beginTransactionHandle returned null');
    }
    try {
      final result = await action(txn);
      txn.commit();
      return result;
    } on Object {
      if (txn.isActive) {
        txn.rollback();
      }
      rethrow;
    }
  }

  // -- Native finalizer (best-effort token reclaim on GC) ----------------
  //
  // We use a static `NativeFinalizer` pointing at `package:ffi`'s
  // `malloc.nativeFree` so that the small `Pointer<Uint64>` token we
  // allocated for tracking gets freed when the Dart object becomes
  // unreachable without explicit commit/rollback.
  //
  // The transaction itself does NOT get rolled back by the finalizer
  // (NativeFinalizer callbacks cannot call back into Dart safely), but the
  // engine's `odbc_disconnect` already iterates `state.transactions` and
  // rolls back any txn still attached to the closing connection (added in
  // v2.0). So the worst-case leak is bounded by the lifetime of the
  // connection, not by the lifetime of the process.

  static final ffi.NativeFinalizer _nativeFinalizer =
      ffi.NativeFinalizer(malloc.nativeFree);

  /// `Pointer<Uint64>` holding the txnId. We allocate it on attach and free
  /// it on detach (or on finalizer fire).
  ffi.Pointer<ffi.Uint64>? _finalizerToken;

  void _attachFinalizer() {
    final token = malloc<ffi.Uint64>()..value = _txnId;
    _finalizerToken = token;
    _nativeFinalizer.attach(this, token.cast(), detach: this);
  }

  void _detachFinalizer() {
    final token = _finalizerToken;
    if (token == null) return;
    _nativeFinalizer.detach(this);
    malloc.free(token);
    _finalizerToken = null;
  }
}

enum _State { active, committed, rolledBack, failed }
