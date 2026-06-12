// FFI bindings mirror exported C symbol names; snake_case identifiers are
// intentional for 1:1 native API mapping.
// ignore_for_file: non_constant_identifier_names

part of 'odbc_bindings.dart';

mixin _OdbcBindingsXa on _OdbcBindingsState {
  void _bindXa() {
    try {
      // Sprint 4.3 — XA / 2PC FFIs added together. Either the native
      // library has all of them or none, so we use a single try block
      // gated on the canonical entry point `odbc_xa_start`.
      _odbc_xa_start_ptr = _dylib.lookup('odbc_xa_start');
      _odbc_xa_end_ptr = _dylib.lookup('odbc_xa_end');
      _odbc_xa_prepare_ptr = _dylib.lookup('odbc_xa_prepare');
      _odbc_xa_commit_prepared_ptr = _dylib.lookup('odbc_xa_commit_prepared');
      _odbc_xa_rollback_prepared_ptr =
          _dylib.lookup('odbc_xa_rollback_prepared');
      _odbc_xa_commit_one_phase_ptr = _dylib.lookup('odbc_xa_commit_one_phase');
      _odbc_xa_rollback_active_ptr = _dylib.lookup('odbc_xa_rollback_active');
      _odbc_xa_recover_count_ptr = _dylib.lookup('odbc_xa_recover_count');
      _odbc_xa_recover_get_ptr = _dylib.lookup('odbc_xa_recover_get');
      _odbc_xa_resume_prepared_ptr = _dylib.lookup('odbc_xa_resume_prepared');
    } on Object catch (_) {
      _odbc_xa_start_ptr = null;
      _odbc_xa_end_ptr = null;
      _odbc_xa_prepare_ptr = null;
      _odbc_xa_commit_prepared_ptr = null;
      _odbc_xa_rollback_prepared_ptr = null;
      _odbc_xa_commit_one_phase_ptr = null;
      _odbc_xa_rollback_active_ptr = null;
      _odbc_xa_recover_count_ptr = null;
      _odbc_xa_recover_get_ptr = null;
      _odbc_xa_resume_prepared_ptr = null;
    }
  }

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_start_func>>? _odbc_xa_start_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_end_func>>? _odbc_xa_end_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_prepare_func>>?
      _odbc_xa_prepare_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_commit_prepared_func>>?
      _odbc_xa_commit_prepared_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_rollback_prepared_func>>?
      _odbc_xa_rollback_prepared_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_commit_one_phase_func>>?
      _odbc_xa_commit_one_phase_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_rollback_active_func>>?
      _odbc_xa_rollback_active_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_recover_count_func>>?
      _odbc_xa_recover_count_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_recover_get_func>>?
      _odbc_xa_recover_get_ptr;

  late ffi.Pointer<ffi.NativeFunction<odbc_xa_resume_prepared_func>>?
      _odbc_xa_resume_prepared_ptr;

  bool get supportsXa => _odbc_xa_start_ptr != null;

  /// True when both multi-result streaming start FFIs and the existing
  /// async-poll FFI are available.

  int odbc_xa_start(
    int connId,
    int formatId,
    ffi.Pointer<ffi.Uint8> gtridPtr,
    int gtridLen,
    ffi.Pointer<ffi.Uint8> bqualPtr,
    int bqualLen,
  ) {
    final ptr = _odbc_xa_start_ptr;
    if (ptr == null) {
      throw _xaUnsupported('odbc_xa_start');
    }
    final fn = ptr.asFunction<
        int Function(
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
        )>();
    return fn(connId, formatId, gtridPtr, gtridLen, bqualPtr, bqualLen);
  }

  int odbc_xa_end(int xaId) {
    final ptr = _odbc_xa_end_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_end');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_prepare(int xaId) {
    final ptr = _odbc_xa_prepare_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_prepare');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_commit_prepared(int xaId) {
    final ptr = _odbc_xa_commit_prepared_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_commit_prepared');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_rollback_prepared(int xaId) {
    final ptr = _odbc_xa_rollback_prepared_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_rollback_prepared');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_commit_one_phase(int xaId) {
    final ptr = _odbc_xa_commit_one_phase_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_commit_one_phase');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_rollback_active(int xaId) {
    final ptr = _odbc_xa_rollback_active_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_rollback_active');
    return ptr.asFunction<int Function(int)>()(xaId);
  }

  int odbc_xa_recover_count(int connId) {
    final ptr = _odbc_xa_recover_count_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_recover_count');
    return ptr.asFunction<int Function(int)>()(connId);
  }

  int odbc_xa_recover_get(
    int index,
    ffi.Pointer<ffi.Int32> outFormatId,
    ffi.Pointer<ffi.Uint8> gtridBuf,
    int gtridBufLen,
    ffi.Pointer<ffi.Uint32> outGtridLen,
    ffi.Pointer<ffi.Uint8> bqualBuf,
    int bqualBufLen,
    ffi.Pointer<ffi.Uint32> outBqualLen,
  ) {
    final ptr = _odbc_xa_recover_get_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_recover_get');
    return ptr.asFunction<
        int Function(
          int,
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint32>,
        )>()(
      index,
      outFormatId,
      gtridBuf,
      gtridBufLen,
      outGtridLen,
      bqualBuf,
      bqualBufLen,
      outBqualLen,
    );
  }

  int odbc_xa_resume_prepared(
    int connId,
    int formatId,
    ffi.Pointer<ffi.Uint8> gtridPtr,
    int gtridLen,
    ffi.Pointer<ffi.Uint8> bqualPtr,
    int bqualLen,
  ) {
    final ptr = _odbc_xa_resume_prepared_ptr;
    if (ptr == null) throw _xaUnsupported('odbc_xa_resume_prepared');
    final fn = ptr.asFunction<
        int Function(
          int,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
          ffi.Pointer<ffi.Uint8>,
          int,
        )>();
    return fn(connId, formatId, gtridPtr, gtridLen, bqualPtr, bqualLen);
  }

  UnsupportedError _xaUnsupported(String fn) => UnsupportedError(
        '$fn: this native library does not export the XA / 2PC FFI '
        'family (Sprint 4.3). Rebuild the native engine from a '
        '3.4+ source tree, or gate on `OdbcBindings.supportsXa` '
        'before calling.',
      );
}
