import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

/// Exception thrown when telemetry operations fail.
class TelemetryException implements Exception {
  const TelemetryException(this.message) : code = 0;

  const TelemetryException.fromCode(this.code) : message = 'Native error code: $code';

  final String message;
  final int code;

  @override
  String toString() => 'TelemetryException: $message (code: $code)';
}

/// Provides access to OpenTelemetry tracing functions from Dart.
///
/// This class provides FFI bindings to the native OpenTelemetry library.
/// It handles initialization, trace export, and cleanup operations.
///
/// NOTE: Native telemetry functions require the DLL to be loaded.
/// If the DLL is not available, operations will be no-ops.
class OpenTelemetryFFI {

  factory OpenTelemetryFFI() {
    final dylib = _loadLibrary();

    // Try to lookup native functions - they may not be available if DLL isn't loaded
    ffi.Pointer<ffi.NativeFunction<otel_init_func>>? otelInitPtr;
    ffi.Pointer<ffi.NativeFunction<otel_export_trace_func>>?
        otelExportTracePtr;
    ffi.Pointer<ffi.NativeFunction<otel_shutdown_func>>? otelShutdownPtr;
    ffi.Pointer<ffi.NativeFunction<otel_get_last_error_func>>?
        otelGetLastErrorPtr;
    ffi.Pointer<ffi.NativeFunction<otel_cleanup_strings_func>>?
        otelCleanupStringsPtr;

    try {
      otelInitPtr = dylib.lookup('otel_init');
      otelExportTracePtr = dylib.lookup('otel_export_trace');
      otelShutdownPtr = dylib.lookup('otel_shutdown');
      otelGetLastErrorPtr = dylib.lookup('otel_get_last_error');
      otelCleanupStringsPtr = dylib.lookup('otel_cleanup_strings');
    } catch (_) {
      // Native functions not available - DLL may not be loaded
    }

    return OpenTelemetryFFI._(
      dylib,
      otelInitPtr,
      otelExportTracePtr,
      otelShutdownPtr,
      otelGetLastErrorPtr,
      otelCleanupStringsPtr,
    );
  }
  OpenTelemetryFFI._(this._dylib, this._otelInit, this._otelExportTrace,
      this._otelShutdown, this._otelGetLastError, this._otelCleanupStrings,);

  static ffi.DynamicLibrary _loadLibrary() {
    if (Platform.isWindows) {
      try {
        return ffi.DynamicLibrary.open('native/odbc_engine/target/release/odbc_engine.dll');
      } catch (_) {
        try {
          return ffi.DynamicLibrary.open('odbc_engine.dll');
        } catch (_) {
          return ffi.DynamicLibrary.process();
        }
      }
    }
    return ffi.DynamicLibrary.process();
  }

  final ffi.DynamicLibrary _dylib;
  final ffi.Pointer<ffi.NativeFunction<otel_init_func>>? _otelInit;
  final ffi.Pointer<ffi.NativeFunction<otel_export_trace_func>>?
      _otelExportTrace;
  final ffi.Pointer<ffi.NativeFunction<otel_shutdown_func>>? _otelShutdown;
  final ffi.Pointer<ffi.NativeFunction<otel_get_last_error_func>>?
      _otelGetLastError;
  final ffi.Pointer<ffi.NativeFunction<otel_cleanup_strings_func>>?
      _otelCleanupStrings;

  bool initialize({String otlpEndpoint = 'http://localhost:4318'}) {
    final ptr = _otelInit;
    if (ptr == null) {
      return false;
    }
    final result = ptr.asFunction<int Function()>()();
    return result == 0;
  }

  void exportTrace(String traceJson) {
    final ptr = _otelExportTrace;
    if (ptr == null) {
      return;
    }

    // NOTE: For now, we can't allocate native memory without ffi.allocate.
    // When native telemetry is fully implemented, we need to:
    // 1. Allocate native memory for the JSON string
    // 2. Copy UTF-8 bytes to native memory
    // 3. Call native function with pointer and length
    // 4. Free native memory after call

    // For now, this is a no-op when native functions aren't available
    try {
      final utf8Bytes = Uint8List.fromList(traceJson.codeUnits);
      // TODO: Allocate native memory and call export function
      // final result = ptr.asFunction<int Function(ffi.Pointer<ffi.Uint8>, int)>()(pointer, utf8Bytes.length);
    } catch (_) {
      // Silently ignore export errors
    }
  }

  (String, int) getLastError() {
    final ptr = _otelGetLastError;
    if (ptr == null) {
      return ('Native telemetry not available', 1);
    }

    // TODO: Implement proper error retrieval when native functions are available
    try {
      final result = ptr.asFunction<
          int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Int32>)>()(
        ffi.Pointer.fromAddress(0),
        ffi.Pointer.fromAddress(0),
      );
      return ('Error code: $result', result);
    } catch (_) {
      return ('Error retrieving last error', 1);
    }
  }

  void shutdown() {
    final ptr = _otelShutdown;
    if (ptr != null) {
      ptr.asFunction<void Function()>()();
    }
  }

  void cleanupStrings() {
    final ptr = _otelCleanupStrings;
    if (ptr != null) {
      ptr.asFunction<void Function()>()();
    }
  }
}

// Native function typedefs
typedef otel_init_func = ffi.Int8 Function();
typedef otel_export_trace_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef otel_shutdown_func = ffi.Void Function();
typedef otel_get_last_error_func = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Int32>,
);
typedef otel_cleanup_strings_func = ffi.Void Function();
