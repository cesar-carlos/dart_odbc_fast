part of 'odbc_native.dart';

mixin _OdbcNativeConnection on _OdbcNativeState {
  /// Validates connection string format without connecting.
  ///
  /// Returns null if valid; error message if invalid (empty, bad UTF-8,
  /// no key=value pairs, unbalanced braces).
  String? validateConnectionString(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    final errorBuf = malloc<ffi.Uint8>(256);
    try {
      final code = _bindings.odbc_validate_connection_string(
        connStrPtr.cast<bindings.Utf8>(),
        errorBuf,
        256,
      );
      if (code == 0) return null;
      final len = errorBuf.asTypedList(256).indexOf(0);
      if (len <= 0) return 'Invalid connection string';
      return utf8.decode(errorBuf.asTypedList(len));
    } finally {
      malloc
        ..free(connStrPtr)
        ..free(errorBuf);
    }
  }

  /// Establishes a new database connection.
  ///
  /// The [connectionString] should be a valid ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  ///
  /// Returns a connection ID on success, 0 on failure.
  int connect(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final connId = _bindings.odbc_connect(connStrPtr.cast<bindings.Utf8>());
      return connId;
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Establishes a connection with a login timeout.
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Returns a connection ID on success, 0 on failure.
  int connectWithTimeout(String connectionString, int timeoutMs) {
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final connId = _bindings.odbc_connect_with_timeout(
        connStrPtr.cast<bindings.Utf8>(),
        timeoutMs,
      );
      return connId;
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier.
  /// Returns true on success, false on failure.
  bool disconnect(int connectionId) {
    final result = _bindings.odbc_disconnect(connectionId);
    return result == 0;
  }

  /// Gets driver capabilities from connection string as UTF-8 JSON object.
  ///
  /// Returns null on FFI failure or when API is unavailable.
  String? getDriverCapabilitiesJson(String connectionString) {
    if (!_bindings.supportsDriverCapabilitiesApi) {
      return null;
    }
    final connStrPtr = connectionString.toNativeUtf8();
    try {
      final data = callWithBuffer(
        (buf, bufLen, outWritten) => _bindings.odbc_get_driver_capabilities(
          connStrPtr.cast<bindings.Utf8>(),
          buf,
          bufLen,
          outWritten,
        ),
      );
      if (data == null) {
        return null;
      }
      return utf8.decode(data);
    } finally {
      malloc.free(connStrPtr);
    }
  }

  /// True when the loaded native library exposes the v2.1 live DBMS
  /// introspection FFI (`odbc_get_connection_dbms_info`).
  bool get supportsConnectionDbmsInfoApi =>
      _bindings.supportsConnectionDbmsInfoApi;

  /// Live DBMS introspection (v2.1). Returns the JSON document produced by
  /// `odbc_get_connection_dbms_info` for the given connection id, or null
  /// when the FFI is unavailable / the call fails.
  ///
  /// Far more accurate than [getDriverCapabilitiesJson] because it queries
  /// the actual driver via `SQLGetInfo(SQL_DBMS_NAME)` instead of parsing
  /// the connection string.
  String? getConnectionDbmsInfoJson(int connectionId) {
    if (!_bindings.supportsConnectionDbmsInfoApi) {
      return null;
    }
    final data = callWithBuffer(
      (buf, bufLen, outWritten) => _bindings.odbc_get_connection_dbms_info(
        connectionId,
        buf,
        bufLen,
        outWritten,
      ),
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres", "mysql",
  /// "mongodb", "sqlite", "sybase") if detected, or null if unknown.
  String? detectDriver(String connectionString) {
    final connStrPtr = connectionString.toNativeUtf8();
    const bufferLen = 64;
    final outBuf = malloc<ffi.Int8>(bufferLen);
    try {
      final result = _bindings.odbc_detect_driver(
        connStrPtr.cast<bindings.Utf8>(),
        outBuf,
        bufferLen,
      );
      if (result != 1) {
        return null;
      }
      final end = outBuf.asTypedList(bufferLen).indexOf(0);
      final len = end < 0 ? bufferLen : end;
      if (len == 0) {
        return null;
      }
      // Cast to Uint8 view — no allocation, no sign-conversion loop.
      return utf8.decode(
        outBuf.cast<ffi.Uint8>().asTypedList(len),
        allowMalformed: true,
      );
    } finally {
      malloc
        ..free(connStrPtr)
        ..free(outBuf);
    }
  }

  /// Gets the last error message from the native engine.
  ///
  /// Returns an empty string if no error occurred.
  String getError() {
    final buf = malloc<ffi.Int8>(_errorBufferSize);
    try {
      final n = _bindings.odbc_get_error(buf, _errorBufferSize);
      if (n < 0) {
        return 'Unknown error';
      }
      if (n == 0) {
        return '';
      }
      // Cast to Uint8 view — no allocation, no sign-conversion loop.
      return utf8.decode(
        buf.cast<ffi.Uint8>().asTypedList(n),
        allowMalformed: true,
      );
    } finally {
      malloc.free(buf);
    }
  }

  /// Enables or disables native audit event collection.
  ///
  /// Returns true when operation succeeds.
  bool setAuditEnabled({required bool enabled}) {
    final result = _bindings.odbc_audit_enable(enabled ? 1 : 0);
    return result == 0;
  }

  /// Clears all in-memory native audit events.
  ///
  /// Returns true on success.
  bool clearAuditEvents() {
    final result = _bindings.odbc_audit_clear();
    return result == 0;
  }

  /// Gets audit events encoded as UTF-8 JSON array.
  ///
  /// Returns null on FFI failure.
  String? getAuditEventsJson({int limit = 0}) {
    final data = callWithBuffer(
      (buf, bufLen, outWritten) =>
          _bindings.odbc_audit_get_events(buf, bufLen, outWritten, limit),
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Gets current audit status encoded as UTF-8 JSON object.
  ///
  /// Returns null on FFI failure.
  String? getAuditStatusJson() {
    final data = callWithBuffer(
      _bindings.odbc_audit_get_status,
    );
    if (data == null) {
      return null;
    }
    return utf8.decode(data);
  }

  /// Gets structured error information including SQLSTATE and native code.
  ///
  /// Returns null if no error occurred or if structured error info
  /// is not available.
  StructuredError? getStructuredError() {
    final data = callWithBuffer(
      _bindings.odbc_get_structured_error,
    );
    if (data == null || data.isEmpty) {
      return null;
    }
    return StructuredError.deserialize(data);
  }

  /// Whether the native library exposes per-connection structured error API.
  bool get supportsStructuredErrorForConnection =>
      _bindings.supportsStructuredErrorForConnection;

  /// Gets structured error for a specific connection (per-connection
  /// isolation).
  ///
  /// When [connectionId] != 0, returns only that connection's error.
  /// Returns null when API is unavailable, no error for this connection,
  /// or on FFI failure.
  StructuredError? getStructuredErrorForConnection(int connectionId) {
    if (!_bindings.supportsStructuredErrorForConnection) {
      return null;
    }

    var size = initialBufferSize;
    const limit = maxBufferSize;
    while (size <= limit) {
      final buf = malloc<ffi.Uint8>(size);
      final outWritten = malloc<ffi.Uint32>()..value = 0;
      try {
        final code = _bindings.odbc_get_structured_error_for_connection(
          connectionId,
          buf,
          size,
          outWritten,
        );
        if (code == null) return null;
        if (code == 1) return null; // No structured error for this connection
        if (code == -1) return null; // FFI error
        if (code == -2) {
          final requested = outWritten.value;
          size = requested > size ? requested : size * 2;
          continue;
        }
        if (code == 0) {
          final n = outWritten.value;
          if (n == 0) return null;
          final data = Uint8List.fromList(buf.asTypedList(n));
          return StructuredError.deserialize(data);
        }
        return null;
      } finally {
        malloc
          ..free(buf)
          ..free(outWritten);
      }
    }
    return null;
  }
}
