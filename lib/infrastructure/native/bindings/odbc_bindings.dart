// FFI bindings must match native C/Rust symbol names exactly.

library;
import 'dart:ffi' as ffi;

part 'odbc_bindings_connection.dart';
part 'odbc_bindings_query.dart';
part 'odbc_bindings_stream.dart';
part 'odbc_bindings_transaction.dart';
part 'odbc_bindings_xa.dart';
part 'odbc_bindings_pool.dart';
part 'odbc_bindings_types.dart';

/// Shared native library handle for [OdbcBindings] mixins.
abstract class _OdbcBindingsState {
  _OdbcBindingsState(this._dylib);

  final ffi.DynamicLibrary _dylib;
}

/// Low-level FFI bindings for the native ODBC engine.
class OdbcBindings extends _OdbcBindingsState
    with
        _OdbcBindingsConnection,
        _OdbcBindingsQuery,
        _OdbcBindingsStream,
        _OdbcBindingsTransaction,
        _OdbcBindingsXa,
        _OdbcBindingsPool {
  OdbcBindings(super._dylib) {
    _bindConnection();
    _bindQuery();
    _bindStream();
    _bindTransaction();
    _bindXa();
    _bindPool();
  }
}
