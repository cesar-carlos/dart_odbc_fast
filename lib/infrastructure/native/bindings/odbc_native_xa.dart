part of 'odbc_native.dart';

mixin _OdbcNativeXa on _OdbcNativeState {
  /// True when the loaded native library exports the XA / 2PC FFI
  /// family (Sprint 4.3). Callers should gate on this before using
  /// any of the [xaStart] / [xaPrepare] / etc. methods — older
  /// binaries throw `UnsupportedError`.
  bool get supportsXa => _bindings.supportsXa;

  // -----------------------------------------------------------------
  // Sprint 4.3 — XA / 2PC distributed transactions.
  //
  // Each method maps 1:1 to an `odbc_xa_*` FFI entry point and does
  // the FFI memory ceremony (alloc/copy/free of the gtrid/bqual byte
  // buffers) so callers see a clean Dart API. Errors surface as the
  // FFI integer return code; callers should pair every call with the
  // existing `getStructuredErrorForConnection` / `getError` lookup.
  // -----------------------------------------------------------------

  /// `xa_start`: open a new XA branch on [connectionId] with the
  /// given XID components. Returns the `xa_id` on success, `0` on
  /// failure.
  int xaStart({
    required int connectionId,
    required int formatId,
    required Uint8List gtrid,
    required Uint8List bqual,
  }) {
    final gtridPtr = _allocBytes(gtrid);
    final bqualPtr = _allocBytes(bqual);
    try {
      return _bindings.odbc_xa_start(
        connectionId,
        formatId,
        gtridPtr,
        gtrid.length,
        bqualPtr,
        bqual.length,
      );
    } finally {
      if (gtridPtr.address != 0) calloc.free(gtridPtr);
      if (bqualPtr.address != 0) calloc.free(bqualPtr);
    }
  }

  /// `xa_end`: detach the branch from the connection. Returns 0 on
  /// success, non-zero on failure.
  int xaEnd(int xaId) => _bindings.odbc_xa_end(xaId);

  /// `xa_prepare`: Phase 1 of 2PC.
  int xaPrepare(int xaId) => _bindings.odbc_xa_prepare(xaId);

  /// `xa_commit` (Phase 2) for a previously prepared branch.
  int xaCommitPrepared(int xaId) => _bindings.odbc_xa_commit_prepared(xaId);

  /// `xa_rollback` (Phase 2) for a previously prepared branch.
  int xaRollbackPrepared(int xaId) => _bindings.odbc_xa_rollback_prepared(xaId);

  /// 1RM optimisation: fuse `prepare → commit` on an active branch
  /// when this RM is the sole participant.
  int xaCommitOnePhase(int xaId) => _bindings.odbc_xa_commit_one_phase(xaId);

  /// Roll back an Active branch (no PREPARE issued). No recovery
  /// path exists after this call.
  int xaRollbackActive(int xaId) => _bindings.odbc_xa_rollback_active(xaId);

  /// `xa_recover`: list every XID currently in the `Prepared` state
  /// on the resource manager. Two-step protocol: this call queries
  /// the engine and returns the count; [xaRecoverGet] extracts the
  /// XID components by index.
  int xaRecoverCount(int connectionId) =>
      _bindings.odbc_xa_recover_count(connectionId);

  /// Extract the XID at [index] from the cache populated by the most
  /// recent [xaRecoverCount] call. Returns `null` when the index is
  /// out of range or the FFI fails.
  ({int formatId, Uint8List gtrid, Uint8List bqual})? xaRecoverGet(int index) {
    // 64-byte buffers cover the X/Open maximum for both gtrid and bqual.
    final gtridBuf = calloc<ffi.Uint8>(64);
    final bqualBuf = calloc<ffi.Uint8>(64);
    final outFormatId = calloc<ffi.Int32>();
    final outGtridLen = calloc<ffi.Uint32>();
    final outBqualLen = calloc<ffi.Uint32>();
    try {
      final rc = _bindings.odbc_xa_recover_get(
        index,
        outFormatId,
        gtridBuf,
        64,
        outGtridLen,
        bqualBuf,
        64,
        outBqualLen,
      );
      if (rc != 0) return null;
      final formatId = outFormatId.value;
      final gtridLen = outGtridLen.value;
      final bqualLen = outBqualLen.value;
      final gtrid = Uint8List.fromList(
        gtridBuf.asTypedList(gtridLen),
      );
      final bqual = Uint8List.fromList(
        bqualBuf.asTypedList(bqualLen),
      );
      return (formatId: formatId, gtrid: gtrid, bqual: bqual);
    } finally {
      calloc
        ..free(gtridBuf)
        ..free(bqualBuf)
        ..free(outFormatId)
        ..free(outGtridLen)
        ..free(outBqualLen);
    }
  }

  /// Resume a previously prepared XID — rebuilds an `xa_id` handle
  /// for crash-recovery scenarios. Returns the `xa_id` on success,
  /// `0` on failure.
  int xaResumePrepared({
    required int connectionId,
    required int formatId,
    required Uint8List gtrid,
    required Uint8List bqual,
  }) {
    final gtridPtr = _allocBytes(gtrid);
    final bqualPtr = _allocBytes(bqual);
    try {
      return _bindings.odbc_xa_resume_prepared(
        connectionId,
        formatId,
        gtridPtr,
        gtrid.length,
        bqualPtr,
        bqual.length,
      );
    } finally {
      if (gtridPtr.address != 0) calloc.free(gtridPtr);
      if (bqualPtr.address != 0) calloc.free(bqualPtr);
    }
  }

  /// Allocate native memory and copy [bytes] into it. Returns a
  /// `nullptr` for empty input (the FFI side accepts that pair as an
  /// empty bqual, which is X/Open-valid). Caller is responsible for
  /// `calloc.free` on the non-null result.
  ffi.Pointer<ffi.Uint8> _allocBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      return ffi.Pointer<ffi.Uint8>.fromAddress(0);
    }
    final ptr = calloc<ffi.Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    return ptr;
  }
}
