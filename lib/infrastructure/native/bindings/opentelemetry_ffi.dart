// ignore_for_file: camel_case_types

import 'dart:ffi' as ffi;
import 'dart:io' as io;

/// Exception thrown when telemetry operations fail.
class TelemetryException implements Exception {
  const TelemetryException(this.message) : code = 0;

  const TelemetryException.fromCode(this.code) : message = 'Native error code: $code';

  final String message;
  final int code;

  @override
  String toString() => 'TelemetryException: $message (code: $code)';
}

/// Provides FFI bindings for OpenTelemetry.
///
/// NOTE: This is a simplified stub implementation. The actual export
/// functionality is handled by the Rust native library's OTLP exporter.
/// Full FFI bindings would require proper memory allocation
/// which is not straightforward in Dart 3.10.7.
class OpenTelemetryFFI {
  /// Creates a new instance and loads the OpenTelemetry library.
  factory OpenTelemetryFFI() {
    try {
      final dylib = _loadLibrary();
      return OpenTelemetryFFI._(dylib);
    } on Object {
      // Fallback when library loading fails
      return OpenTelemetryFFI._(ffi.DynamicLibrary.process());
    }
  }

  OpenTelemetryFFI._(this._dylib);

  final ffi.DynamicLibrary _dylib;

  /// Loads the native OpenTelemetry library.
  static ffi.DynamicLibrary _loadLibrary() {
    if (io.Platform.isWindows) {
      try {
        return ffi.DynamicLibrary.open('native/odbc_engine/target/release/odbc_engine.dll');
      } on Object {
        try {
          return ffi.DynamicLibrary.open('odbc_engine.dll');
        } on Object {
          return ffi.DynamicLibrary.process();
        }
      }
    }
    return ffi.DynamicLibrary.process();
  }

  bool initialize({String otlpEndpoint = 'http://localhost:4318'}) {
    // NOTE: Initialize is handled by the Rust native library
    // This stub returns true for compatibility
    return true;
  }

  void exportTrace(String traceJson) {
    // NOTE: Native telemetry export is handled by the Rust OTLP exporter.
    // This stub does nothing for compatibility.
  }

  (String, int) getLastError() {
    return ('Stub not implemented', 1);
  }

  void shutdown() {
    // NOTE: Shutdown is handled by the Rust native library
    // This stub does nothing for compatibility.
  }

  void cleanupStrings() {
    // NOTE: Cleanup is handled by the Rust native library
    // This stub does nothing for compatibility.
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
