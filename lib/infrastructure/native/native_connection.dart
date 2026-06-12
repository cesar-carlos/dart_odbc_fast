part of 'native_odbc_connection.dart';

mixin _NativeConnection on _NativeOdbcState {
  /// Initializes the ODBC environment.
  ///
  /// Must be called before any other operations. This method can be called
  /// multiple times safely - subsequent calls are ignored if already
  /// initialized.
  ///
  /// Returns true on success, false on failure.
  bool initialize() {
    if (_isInitialized) return true;

    final result = _native.init();
    if (result) {
      _isInitialized = true;
    }
    return result;
  }

  /// Establishes a new database connection.
  ///
  /// The [connectionString] should be a valid ODBC connection string
  /// (e.g., 'DSN=MyDatabase' or 'Driver={SQL Server};Server=...').
  ///
  /// Returns a connection ID on success, 0 on failure.
  /// Throws [StateError] if the environment has not been initialized.
  int connect(String connectionString) {
    if (!_isInitialized) {
      throw StateError('Environment not initialized');
    }
    return _native.connect(connectionString);
  }

  /// Establishes a connection with a login timeout.
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Returns a connection ID on success, 0 on failure.
  int connectWithTimeout(String connectionString, int timeoutMs) {
    if (!_isInitialized) {
      throw StateError('Environment not initialized');
    }
    return _native.connectWithTimeout(connectionString, timeoutMs);
  }

  /// Closes and disconnects a connection.
  ///
  /// The [connectionId] must be a valid connection identifier returned
  /// from [connect]. Returns true on success, false on failure.
  bool disconnect(int connectionId) {
    return _native.disconnect(connectionId);
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres") if
  /// detected, or null if unknown.
  String? detectDriver(String connectionString) =>
      _native.detectDriver(connectionString);

  /// Validates connection string format without opening a connection.
  ///
  /// Returns null when valid; otherwise a human-readable validation message.
  String? validateConnectionString(String connectionString) =>
      _native.validateConnectionString(connectionString);

  /// Whether the loaded native library supports driver capabilities FFI API.
  bool get supportsDriverCapabilitiesApi =>
      _native.supportsDriverCapabilitiesApi;

  /// Returns typed driver capabilities from [connectionString], or null when
  /// API is unavailable or invalid.
  DriverCapabilities? getDriverCapabilities(String connectionString) =>
      OdbcDriverCapabilities(_native).getCapabilities(connectionString);

  /// Returns driver capabilities payload as JSON, or null on failure.
  String? getDriverCapabilitiesJson(String connectionString) =>
      _native.getDriverCapabilitiesJson(connectionString);

  /// Sets native engine log verbosity (0=off, 5=trace).
  void setLogLevel(int level) => _native.setLogLevel(level);

  /// Whether the loaded native library exposes live DBMS introspection
  /// (v2.1 `odbc_get_connection_dbms_info`).
  bool get supportsConnectionDbmsInfoApi =>
      _native.supportsConnectionDbmsInfoApi;

  /// Returns the live DBMS introspection JSON for [connectionId], or null
  /// when the call fails or the API is unavailable. Use the high-level
  /// `OdbcDriverCapabilities.getDbmsInfoForConnection` to obtain a typed
  /// `DbmsInfo` instead of raw JSON.
  String? getConnectionDbmsInfoJson(int connectionId) =>
      _native.getConnectionDbmsInfoJson(connectionId);

  /// Gets the last error message from the native engine.
  ///
  /// Returns an empty string if no error occurred.
  String getError() => _native.getError();

  /// Gets structured error information including SQLSTATE and native code.
  ///
  /// Returns null if no error occurred or if structured error info
  /// is not available.
  StructuredError? getStructuredError() => _native.getStructuredError();

  /// Whether the native library supports per-connection structured error API.
  bool get supportsStructuredErrorForConnection =>
      _native.supportsStructuredErrorForConnection;

  /// Gets structured error for a specific connection (per-connection
  /// isolation).
  ///
  /// When [connectionId] != 0, returns only that connection's error.
  /// Returns null when API is unavailable, no error for this connection,
  /// or on FFI failure.
  StructuredError? getStructuredErrorForConnection(int connectionId) =>
      _native.getStructuredErrorForConnection(connectionId);
}
