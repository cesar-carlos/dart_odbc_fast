part of 'odbc_native.dart';

mixin _OdbcNativeTransaction on _OdbcNativeState {
  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3 — see
  /// `IsolationLevel`).
  /// The [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved on the Rust side via SQLGetInfo).
  /// The [accessMode] is the wire code from `TransactionAccessMode.code`
  /// (default `0` = `readWrite`). Non-default values require
  /// [supportsTransactionAccessMode]; otherwise throws
  /// [UnsupportedFeatureError].
  /// The [lockTimeoutMs] is the per-transaction lock timeout in
  /// milliseconds (default `0` = engine default). Non-zero values require
  /// [supportsTransactionLockTimeout]; otherwise throws
  /// [UnsupportedFeatureError].
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int transactionBegin(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) {
    if (accessMode != 0 && !_bindings.supportsTransactionAccessMode) {
      throw const UnsupportedFeatureError(
        message: 'TransactionAccessMode requires native symbol '
            'odbc_transaction_begin_v2. Upgrade odbc_engine or use '
            'TransactionAccessMode.readWrite.',
      );
    }
    if (lockTimeoutMs != 0 && !_bindings.supportsTransactionLockTimeout) {
      throw const UnsupportedFeatureError(
        message: 'Per-transaction lockTimeoutMs requires native symbol '
            'odbc_transaction_begin_v3. Upgrade odbc_engine or omit '
            'lockTimeout.',
      );
    }
    if (accessMode == 0 && lockTimeoutMs == 0) {
      // Stay on the v1 entry-point when the caller is OK with every
      // engine default. Avoids touching v2/v3 at all so any FFI
      // mismatch surfaces only when the caller actually asks for the
      // newer features.
      return _bindings.odbc_transaction_begin(
        connectionId,
        isolationLevel,
        savepointDialect,
      );
    }
    if (lockTimeoutMs == 0) {
      // Caller wants accessMode but not the timeout — stay on v2 so
      // we don't require a v3 binary unnecessarily.
      return _bindings.odbc_transaction_begin_v2(
        connectionId,
        isolationLevel,
        savepointDialect,
        accessMode,
      );
    }
    return _bindings.odbc_transaction_begin_v3(
      connectionId,
      isolationLevel,
      savepointDialect,
      accessMode,
      lockTimeoutMs,
    );
  }

  /// True when the loaded native library exports `odbc_transaction_begin_v2`
  /// (Sprint 4.1). Callers that intend to pass a non-default `accessMode`
  /// should gate on this flag.
  bool get supportsTransactionAccessMode =>
      _bindings.supportsTransactionAccessMode;

  /// True when the loaded native library exports `odbc_transaction_begin_v3`
  /// (Sprint 4.2). Callers that intend to pass a non-default
  /// `lockTimeoutMs` should gate on this flag.
  bool get supportsTransactionLockTimeout =>
      _bindings.supportsTransactionLockTimeout;

  /// Commits a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool transactionCommit(int txnId) {
    return _bindings.odbc_transaction_commit(txnId) == 0;
  }

  /// Rolls back a transaction.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool transactionRollback(int txnId) {
    return _bindings.odbc_transaction_rollback(txnId) == 0;
  }

  /// Creates a savepoint within an active transaction.
  ///
  /// The [txnId] must be a valid transaction identifier from
  /// [transactionBegin]. Returns true on success, false on failure.
  bool savepointCreate(int txnId, String name) {
    final namePtr = _sqlCache.acquire(name);
    return _bindings.odbc_savepoint_create(txnId, namePtr) == 0;
  }

  /// Rolls back to a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool savepointRollback(int txnId, String name) {
    final namePtr = _sqlCache.acquire(name);
    return _bindings.odbc_savepoint_rollback(txnId, namePtr) == 0;
  }

  /// Releases a savepoint. The transaction remains active.
  ///
  /// The [txnId] must be a valid transaction identifier.
  /// Returns true on success, false on failure.
  bool savepointRelease(int txnId, String name) {
    final namePtr = _sqlCache.acquire(name);
    return _bindings.odbc_savepoint_release(txnId, namePtr) == 0;
  }
}
