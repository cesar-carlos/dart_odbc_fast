part of 'async_native_odbc_connection.dart';

mixin _AsyncConnection on _AsyncOdbcState, _AsyncWorkerDispatch {
  /// Opens a connection in the worker using [connectionString].
  ///
  /// [timeoutMs] is the login timeout in milliseconds (0 = driver default).
  /// Throws [AsyncError] with [AsyncErrorCode.connectionFailed] if the
  /// connection fails. Call `initialize` before `connect`.
  ///
  /// Returns the native connection ID (positive integer) on success.
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (!_isInitialized) {
      throw const AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Environment not initialized. Call initialize() first.',
      );
    }
    final r = await _sendRequest<ConnectResponse>(
      ConnectRequest(_nextRequestId(), connectionString, timeoutMs: timeoutMs),
    );
    if (r.error != null) {
      throw AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: r.error!,
      );
    }
    return r.connectionId;
  }

  /// Closes the connection identified by [connectionId] in the worker.
  ///
  /// Returns `true` if disconnect succeeded, `false` otherwise.
  Future<bool> disconnect(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      DisconnectRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Returns the last error message from the worker (plain text).
  Future<String> getError() async {
    final r =
        await _sendRequest<GetErrorResponse>(GetErrorRequest(_nextRequestId()));
    return r.message;
  }

  /// Detects the database driver from a connection string.
  ///
  /// Returns the driver name (e.g. "sqlserver", "oracle", "postgres") if
  /// detected, or null if unknown.
  Future<String?> detectDriver(String connectionString) async {
    final r = await _sendRequest<DetectDriverResponse>(
      DetectDriverRequest(_nextRequestId(), connectionString),
    );
    return r.driverName;
  }

  /// Validates connection string format without opening a connection.
  ///
  /// Returns null when valid; otherwise a human-readable validation message.
  Future<String?> validateConnectionString(String connectionString) async {
    final r = await _sendRequest<ValidateConnectionStringResponse>(
      ValidateConnectionStringRequest(_nextRequestId(), connectionString),
    );
    if (r.isValid) {
      return null;
    }
    return r.errorMessage ?? 'Invalid connection string';
  }

  /// Returns driver capabilities payload as JSON, or null on failure.
  Future<String?> getDriverCapabilitiesJson(String connectionString) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      GetDriverCapabilitiesRequest(_nextRequestId(), connectionString),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Returns live DBMS introspection payload as JSON, or null on failure.
  Future<String?> getConnectionDbmsInfoJson(int connectionId) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      GetConnectionDbmsInfoRequest(_nextRequestId(), connectionId),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Sets native engine log verbosity in the worker.
  Future<void> setLogLevel(int level) async {
    await _sendRequest<BoolResponse>(
      SetLogLevelRequest(_nextRequestId(), level),
    );
  }

  /// Returns the last structured error (message, SQLSTATE, native code), or
  /// `null` if there is no error.
  Future<StructuredError?> getStructuredError() async {
    final r = await _sendRequest<StructuredErrorResponse>(
      GetStructuredErrorRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    if (r.message.isEmpty && r.sqlStateString == null) return null;
    final sqlState = (r.sqlStateString ?? '').codeUnits;
    return StructuredError(
      message: r.message,
      sqlState: sqlState.isNotEmpty ? sqlState : List.filled(5, 0),
      nativeCode: r.nativeCode ?? 0,
    );
  }

  /// Returns the last structured error for [connectionId], or `null` when
  /// there is no connection-scoped error information.
  Future<StructuredError?> getStructuredErrorForConnection(
    int connectionId,
  ) async {
    final r = await _sendRequest<StructuredErrorResponse>(
      GetStructuredErrorForConnectionRequest(
        _nextRequestId(),
        connectionId,
      ),
    );
    if (r.error != null) return null;
    if (r.message.isEmpty && r.sqlStateString == null) return null;
    final sqlState = (r.sqlStateString ?? '').codeUnits;
    return StructuredError(
      message: r.message,
      sqlState: sqlState.isNotEmpty ? sqlState : List.filled(5, 0),
      nativeCode: r.nativeCode ?? 0,
    );
  }
}
