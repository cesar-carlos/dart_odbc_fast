library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart'
    show PreparedStatementMetrics;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart'
    show callWithBuffer, initialBufferSize, maxBufferSize;
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/bindings/sql_pointer_cache.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

part 'odbc_native_helpers.dart';
part 'odbc_native_connection.dart';
part 'odbc_native_query.dart';
part 'odbc_native_transaction.dart';
part 'odbc_native_xa.dart';
part 'odbc_native_stream.dart';
part 'odbc_native_pool.dart';
part 'odbc_native_types.dart';

/// Error buffer size for retrieving error messages (4 KB).
const int _errorBufferSize = 4096;

/// Default chunk size for streaming queries (1000 rows).
const int _defaultStreamChunkSize = 1000;

/// Shared native state for [OdbcNative] mixins.
abstract class _OdbcNativeState {
  _OdbcNativeState(bindings.OdbcBindings injected) : _bindings = injected;

  final bindings.OdbcBindings _bindings;

  /// Per-instance LRU cache of native UTF-8 SQL pointers.
  final SqlPointerCache _sqlCache = SqlPointerCache();
}

/// Native ODBC bindings wrapper.
///
/// Provides a high-level Dart interface to the native ODBC engine
/// through FFI bindings. Handles connection management, queries,
/// transactions, prepared statements, connection pooling, and streaming.
class OdbcNative extends _OdbcNativeState
    with
        _OdbcNativeHelpers,
        _OdbcNativeConnection,
        _OdbcNativeQuery,
        _OdbcNativeTransaction,
        _OdbcNativeXa,
        _OdbcNativeStream,
        _OdbcNativePool {
  /// Creates a new [OdbcNative] instance.
  ///
  /// Automatically loads the ODBC engine library and initializes bindings.
  OdbcNative() : super(bindings.OdbcBindings(loadOdbcLibrary()));

  /// Creates an instance backed by injected [bindings] (unit tests only).
  @visibleForTesting
  OdbcNative.withBindings(super.injected);

  /// Diagnostic counters for the SQL pointer cache. Useful from benchmarks
  /// to verify that hot paths actually hit. Not part of the public API
  /// surface; consider it advisory.
  ({int hits, int misses, int evictions}) get sqlCacheStats => _sqlCache.stats;

  /// Read-only access to the raw bindings. Use only for new capabilities
  /// implemented in companion modules (e.g. `driver_capabilities_v3.dart`).
  bindings.OdbcBindings get rawBindings => _bindings;

  /// Re-export of the buffer-allocation helper so capability modules can
  /// reuse the same retry/grow logic used internally.
  Uint8List? execWithBuffer(
    int Function(
      ffi.Pointer<ffi.Uint8> buf,
      int bufLen,
      ffi.Pointer<ffi.Uint32> outWritten,
    ) op,
  ) =>
      callWithBuffer(op);

  /// True when the loaded native library exposes the audit FFI API.
  bool get supportsAuditApi => _bindings.supportsAuditApi;

  /// True when the loaded native library exposes driver capabilities FFI API.
  bool get supportsDriverCapabilitiesApi =>
      _bindings.supportsDriverCapabilitiesApi;

  /// True when the loaded native library exposes async execute FFI APIs.
  bool get supportsAsyncExecuteApi => _bindings.supportsAsyncExecuteApi;

  /// True when async execute also supports serialized parameter buffers.
  bool get supportsAsyncExecuteParamsApi =>
      _bindings.supportsAsyncExecuteParamsApi;

  /// True when async parameterized execution supports [ResultEncoding] (v3.9+).
  bool get supportsAsyncExecuteParamsOptionsApi =>
      _bindings.supportsAsyncExecuteParamsOptionsApi;

  /// True when the native library exposes result encoding options for direct
  /// parameterized query execution.
  bool get supportsResultEncodingOptions =>
      _bindings.supportsExecQueryParamsOptions;

  /// True when the loaded native library exposes async stream FFI APIs.
  bool get supportsAsyncStreamApi => _bindings.supportsAsyncStreamApi;

  /// True when the loaded native library exposes metadata cache FFI APIs.
  bool get supportsMetadataCacheApi => _bindings.supportsMetadataCacheApi;

  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations.
  /// Returns true on success, false on failure.
  bool init() {
    final result = _bindings.odbc_init();
    return result == 0;
  }

  /// Sets the native engine log level (0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug,
  /// 5=Trace). A logger must be initialized by the host for output to appear.
  void setLogLevel(int level) {
    _bindings.odbc_set_log_level(level);
  }

  /// Returns engine version (api + abi) for client compatibility checks.
  ///
  /// Example: `{"api": "0.1.0", "abi": "1.0.0"}`.
  /// Returns null on failure.
  Map<String, String>? getVersion() {
    const bufSize = 128;
    final buf = malloc<ffi.Uint8>(bufSize);
    final outWritten = malloc<ffi.Uint32>();
    try {
      final code = _bindings.odbc_get_version(buf, bufSize, outWritten);
      if (code != 0) return null;
      final n = outWritten.value;
      if (n == 0) return null;
      final json = utf8.decode(buf.asTypedList(n));
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return {
        'api': decoded['api'] as String? ?? '',
        'abi': decoded['abi'] as String? ?? '',
      };
    } on Object catch (_) {
      return null;
    } finally {
      malloc
        ..free(buf)
        ..free(outWritten);
    }
  }

  /// Disposes of native resources.
  ///
  /// Should be called when the instance is no longer needed.
  void dispose() {
    _sqlCache.dispose();
  }
}
