import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';

/// OpenTelemetry FFI wrapper backed by the native ODBC engine library.
///
/// For backward compatibility with previous stub behavior:
/// - Success is returned as `1`
/// - Failure is returned as `0`/non-zero native code
class OpenTelemetryFFI {
  OpenTelemetryFFI() : this._();

  OpenTelemetryFFI._() {
    _library = loadOdbcLibrary();
    _bindSymbols();
  }

  static const int _errorBufferSize = 8 * 1024;

  late final ffi.DynamicLibrary _library;

  ffi.Pointer<
      ffi.NativeFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Int8>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint8>,
          )>>? _otelInitPtr;
  ffi.Pointer<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr)>>?
      _otelExportTracePtr;
  ffi.Pointer<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr)>>?
      _otelExportTraceToStringPtr;
  ffi.Pointer<
      ffi.NativeFunction<
          ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.IntPtr>,
          )>>? _otelGetLastErrorPtr;
  ffi.Pointer<ffi.NativeFunction<ffi.Void Function()>>? _otelCleanupStringsPtr;
  ffi.Pointer<ffi.NativeFunction<ffi.Void Function()>>? _otelShutdownPtr;

  bool _initialized = false;
  String _lastLocalError = '';

  bool get _symbolsAvailable =>
      _otelInitPtr != null &&
      _otelExportTracePtr != null &&
      _otelExportTraceToStringPtr != null &&
      _otelGetLastErrorPtr != null &&
      _otelCleanupStringsPtr != null &&
      _otelShutdownPtr != null;

  void _bindSymbols() {
    try {
      _otelInitPtr = _library.lookup('otel_init');
      _otelExportTracePtr = _library.lookup('otel_export_trace');
      _otelExportTraceToStringPtr =
          _library.lookup('otel_export_trace_to_string');
      _otelGetLastErrorPtr = _library.lookup('otel_get_last_error');
      _otelCleanupStringsPtr = _library.lookup('otel_cleanup_strings');
      _otelShutdownPtr = _library.lookup('otel_shutdown');
    } on Object catch (_) {
      _lastLocalError =
          'OpenTelemetry symbols not found in loaded native library.';
      _otelInitPtr = null;
      _otelExportTracePtr = null;
      _otelExportTraceToStringPtr = null;
      _otelGetLastErrorPtr = null;
      _otelCleanupStringsPtr = null;
      _otelShutdownPtr = null;
    }
  }

  int _legacySuccessCode(int nativeCode) => nativeCode == 0 ? 1 : nativeCode;

  /// Initializes telemetry exporter.
  ///
  /// Returns `1` on success to preserve legacy behavior.
  int initialize([String otlpEndpoint = '']) {
    if (!_symbolsAvailable) {
      return 0;
    }

    final endpointPtr = otlpEndpoint.toNativeUtf8();
    try {
      final result = _otelInitPtr!.asFunction<
          int Function(
            ffi.Pointer<ffi.Int8>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint8>,
          )>()(
        endpointPtr.cast<ffi.Int8>(),
        ffi.nullptr,
        ffi.nullptr,
      );
      if (result == 0) {
        _initialized = true;
      } else {
        _captureNativeError();
      }
      return _legacySuccessCode(result);
    } finally {
      malloc.free(endpointPtr);
    }
  }

  /// Exports a single trace JSON payload.
  int exportTrace(String traceJson) {
    if (!_initialized) {
      throw Exception('Not initialized');
    }
    if (!_symbolsAvailable) {
      return -1;
    }

    final bytes = utf8.encode(traceJson);
    final ptr = malloc<ffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      final result = _otelExportTracePtr!
          .asFunction<int Function(ffi.Pointer<ffi.Uint8>, int)>()(
        ptr,
        bytes.length,
      );
      if (result != 0) {
        _captureNativeError();
      }
      return _legacySuccessCode(result);
    } finally {
      malloc.free(ptr);
    }
  }

  /// Exports trace data to an output buffer (native behavior dependent).
  int exportTraceToString(String input) {
    if (!_initialized) {
      throw Exception('Not initialized');
    }
    if (!_symbolsAvailable) {
      return -1;
    }

    final encoded = utf8.encode(input);
    final len = encoded.isEmpty ? 1 : encoded.length;
    final out = malloc<ffi.Uint8>(len);
    try {
      if (encoded.isNotEmpty) {
        out.asTypedList(len).setAll(0, encoded);
      } else {
        out.value = 0;
      }
      final result = _otelExportTraceToStringPtr!
          .asFunction<int Function(ffi.Pointer<ffi.Uint8>, int)>()(
        out,
        len,
      );
      if (result != 0) {
        _captureNativeError();
      }
      return _legacySuccessCode(result);
    } finally {
      malloc.free(out);
    }
  }

  int exportSpan(String spanJson) => exportTrace(spanJson);
  int exportMetric(String metricJson) => exportTrace(metricJson);
  int exportEvent(String eventJson) => exportTrace(eventJson);

  int updateTrace(String traceId, String endTime, String attributesJson) =>
      exportTrace(
        '{"trace_id":"$traceId",'
        '"end_time":"$endTime",'
        '"attributes":$attributesJson}',
      );

  int updateSpan(String spanId, String endTime, String attributesJson) =>
      exportTrace(
        '{"span_id":"$spanId",'
        '"end_time":"$endTime",'
        '"attributes":$attributesJson}',
      );

  int flush() => 1;

  int shutdown() {
    final shutdownPtr = _otelShutdownPtr;
    if (shutdownPtr != null) {
      shutdownPtr.asFunction<void Function()>()();
    }
    _initialized = false;
    return 1;
  }

  String _readNativeLastError() {
    final getErrorPtr = _otelGetLastErrorPtr;
    if (getErrorPtr == null) {
      return _lastLocalError;
    }

    final buffer = malloc<ffi.Uint8>(_errorBufferSize);
    final len = malloc<ffi.IntPtr>()..value = 0;
    try {
      final result = getErrorPtr.asFunction<
          int Function(
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.IntPtr>,
          )>()(
        buffer,
        len,
      );
      if (result != 0) {
        return _lastLocalError;
      }

      final nativeLen = len.value;
      if (nativeLen <= 0) {
        return '';
      }
      final safeLen =
          nativeLen > _errorBufferSize ? _errorBufferSize : nativeLen;
      final bytes =
          buffer.asTypedList(safeLen).takeWhile((b) => b != 0).toList();
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      malloc
        ..free(buffer)
        ..free(len);
    }
  }

  void _captureNativeError() {
    final nativeError = _readNativeLastError();
    if (nativeError.isNotEmpty && nativeError != 'No error') {
      _lastLocalError = nativeError;
    }
  }

  String getLastErrorMessage() {
    final nativeError = _readNativeLastError();
    if (nativeError.isNotEmpty && nativeError != 'No error') {
      return nativeError;
    }
    return _lastLocalError;
  }
}
