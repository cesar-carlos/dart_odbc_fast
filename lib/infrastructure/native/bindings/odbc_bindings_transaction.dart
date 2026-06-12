// ignore_for_file: non_constant_identifier_names

part of 'odbc_bindings.dart';

mixin _OdbcBindingsTransaction on _OdbcBindingsState {
  void _bindTransaction() {
    _odbc_transaction_begin_ptr = _dylib.lookup('odbc_transaction_begin');
    try {
      _odbc_transaction_begin_v2_ptr =
          _dylib.lookup('odbc_transaction_begin_v2');
    } on Object catch (_) {
      // Older native libraries (pre-Sprint 4.1) only ship v1. Callers
      // that require READ ONLY support gate on `supportsTransactionAccessMode`.
      _odbc_transaction_begin_v2_ptr = null;
    }
    try {
      _odbc_transaction_begin_v3_ptr =
          _dylib.lookup('odbc_transaction_begin_v3');
    } on Object catch (_) {
      // Older native libraries (pre-Sprint 4.2) don't ship v3. Callers
      // that require lock_timeout support gate on
      // `supportsTransactionLockTimeout`.
      _odbc_transaction_begin_v3_ptr = null;
    }
    _odbc_transaction_commit_ptr = _dylib.lookup('odbc_transaction_commit');
    _odbc_transaction_rollback_ptr = _dylib.lookup('odbc_transaction_rollback');
    _odbc_savepoint_create_ptr = _dylib.lookup('odbc_savepoint_create');
    _odbc_savepoint_rollback_ptr = _dylib.lookup('odbc_savepoint_rollback');
    _odbc_savepoint_release_ptr = _dylib.lookup('odbc_savepoint_release');
  }

  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_begin_func>>
      _odbc_transaction_begin_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_transaction_begin_v2_func>>?
      _odbc_transaction_begin_v2_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_transaction_begin_v3_func>>?
      _odbc_transaction_begin_v3_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_commit_func>>
      _odbc_transaction_commit_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_transaction_rollback_func>>
      _odbc_transaction_rollback_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_create_func>>
      _odbc_savepoint_create_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_rollback_func>>
      _odbc_savepoint_rollback_ptr;

  late final ffi.Pointer<ffi.NativeFunction<odbc_savepoint_release_func>>
      _odbc_savepoint_release_ptr;
  // Sprint 4.3 — XA / 2PC. All ten pointers are optional (look-up
  // wrapped in a single try block above); a missing ABI surfaces via
  // `supportsXa` as `false` so callers can degrade gracefully.

  bool get supportsTransactionAccessMode =>
      _odbc_transaction_begin_v2_ptr != null;

  /// True when the loaded native library exports
  /// `odbc_transaction_begin_v3` (added in Sprint 4.2). Callers that need
  /// the `lockTimeoutMs` parameter should gate on this flag; older
  /// binaries silently fall back to v2 (or v1, depending on what they
  /// export) and the lock-timeout argument is ignored — every
  /// transaction uses the engine default.

  bool get supportsTransactionLockTimeout =>
      _odbc_transaction_begin_v3_ptr != null;

  /// True when the loaded native library exports the XA / 2PC FFI
  /// family (Sprint 4.3). All ten entry points (`odbc_xa_start`,
  /// `_end`, `_prepare`, `_commit_prepared`, `_rollback_prepared`,
  /// `_commit_one_phase`, `_rollback_active`, `_recover_count`,
  /// `_recover_get`, `_resume_prepared`) ship together. The Dart-
  /// side wrappers throw `UnsupportedError` when called against an
  /// older binary; high-level callers should gate on this flag.

  int odbc_transaction_begin(
    int connId,
    int isolationLevel, [
    int savepointDialect = 0,
  ]) =>
      _odbc_transaction_begin_ptr.asFunction<int Function(int, int, int)>()(
        connId,
        isolationLevel,
        savepointDialect,
      );

  /// Sprint 4.1 — begin a transaction with the access-mode hint
  /// (`READ ONLY` / `READ WRITE`).
  ///
  /// Returns the transaction id (`> 0`) on success, `0` on failure (call
  /// `odbc_get_last_error`). When the loaded native library predates v3.4
  /// (`supportsTransactionAccessMode == false`), this falls through to
  /// the v1 entry-point and the `accessMode` argument is ignored —
  /// always `READ WRITE`. Use the `supports*` getter to detect the
  /// capability and emit a friendly fallback at the higher layers.

  int odbc_transaction_begin_v2(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
  ) {
    final ptr = _odbc_transaction_begin_v2_ptr;
    if (ptr == null) {
      // Graceful degradation: fall back to v1 so existing tooling that
      // bundles an older `.so`/`.dll` keeps working. The caller loses
      // READ ONLY semantics but never the transaction itself.
      return odbc_transaction_begin(
        connId,
        isolationLevel,
        savepointDialect,
      );
    }
    return ptr.asFunction<int Function(int, int, int, int)>()(
      connId,
      isolationLevel,
      savepointDialect,
      accessMode,
    );
  }

  /// Sprint 4.2 — begin a transaction with full control over isolation,
  /// savepoint dialect, access mode AND per-transaction lock timeout.
  ///
  /// `lockTimeoutMs = 0` means "use the engine default" — strictly
  /// equivalent to calling [`odbc_transaction_begin_v2`]. Any other
  /// positive value is the maximum number of milliseconds a statement
  /// inside the transaction will wait for a lock.
  ///
  /// When the loaded native library predates Sprint 4.2
  /// (`supportsTransactionLockTimeout == false`), this falls through to
  /// the v2 entry-point and `lockTimeoutMs` is ignored. Use the
  /// `supports*` getter to detect the capability at the high level.

  int odbc_transaction_begin_v3(
    int connId,
    int isolationLevel,
    int savepointDialect,
    int accessMode,
    int lockTimeoutMs,
  ) {
    final ptr = _odbc_transaction_begin_v3_ptr;
    if (ptr == null) {
      return odbc_transaction_begin_v2(
        connId,
        isolationLevel,
        savepointDialect,
        accessMode,
      );
    }
    return ptr.asFunction<int Function(int, int, int, int, int)>()(
      connId,
      isolationLevel,
      savepointDialect,
      accessMode,
      lockTimeoutMs,
    );
  }

  int odbc_transaction_commit(int txnId) =>
      _odbc_transaction_commit_ptr.asFunction<int Function(int)>()(txnId);

  int odbc_transaction_rollback(int txnId) =>
      _odbc_transaction_rollback_ptr.asFunction<int Function(int)>()(txnId);

  int odbc_savepoint_create(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_create_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  int odbc_savepoint_rollback(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_rollback_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  int odbc_savepoint_release(int txnId, ffi.Pointer<Utf8> name) =>
      _odbc_savepoint_release_ptr
          .asFunction<int Function(int, ffi.Pointer<Utf8>)>()(txnId, name);

  // -----------------------------------------------------------------
  // Sprint 4.3 — XA / 2PC. Each wrapper throws UnsupportedError when
  // the loaded native library predates Sprint 4.3 (see `supportsXa`).
  // -----------------------------------------------------------------
}
