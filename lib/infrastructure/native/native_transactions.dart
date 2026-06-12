part of 'native_odbc_connection.dart';

mixin _NativeTransactions on _NativeOdbcState {
  /// Begins a new transaction with the specified isolation level.
  ///
  /// The [connectionId] must be a valid active connection.
  /// The [isolationLevel] should be a numeric value (0-3) corresponding
  /// to isolation level enum values (0=ReadUncommitted, 1=ReadCommitted,
  /// 2=RepeatableRead, 3=Serializable).
  /// The [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved by the Rust engine via SQLGetInfo).
  /// The [accessMode] is the wire code from `TransactionAccessMode.code`
  /// (default `0` = `readWrite`). Sprint 4.1.
  /// The [lockTimeoutMs] is the per-transaction lock timeout in
  /// milliseconds (default `0` = engine default). Sprint 4.2.
  ///
  /// Returns a transaction ID on success, 0 on failure.
  int beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) =>
      _native.transactionBegin(
        connectionId,
        isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeoutMs: lockTimeoutMs,
      );

  /// Begins a new transaction and returns a [TransactionHandle] wrapper.
  ///
  /// See [beginTransaction] for the parameter contract.
  /// Returns a [TransactionHandle] on success, null on failure.
  TransactionHandle? beginTransactionHandle(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) {
    final txnId = beginTransaction(
      connectionId,
      isolationLevel,
      savepointDialect: savepointDialect,
      accessMode: accessMode,
      lockTimeoutMs: lockTimeoutMs,
    );
    if (txnId == 0) return null;
    return TransactionHandle(_connection, txnId);
  }

  /// True when the loaded native library supports
  /// `odbc_transaction_begin_v2` (Sprint 4.1, the `accessMode` parameter
  /// of [beginTransaction]). When false, `accessMode` is silently ignored
  /// and every transaction is `READ WRITE`.
  bool get supportsTransactionAccessMode =>
      _native.supportsTransactionAccessMode;

  /// True when the loaded native library supports
  /// `odbc_transaction_begin_v3` (Sprint 4.2, the `lockTimeoutMs`
  /// parameter of [beginTransaction]). When false, `lockTimeoutMs` is
  /// silently ignored and every transaction uses the engine default
  /// lock timeout.
  bool get supportsTransactionLockTimeout =>
      _native.supportsTransactionLockTimeout;

  /// True when the loaded native library supports the XA / 2PC FFI
  /// family (Sprint 4.3). Callers should gate on this before invoking
  /// [xaStart] / [xaRecover] / [xaResumePrepared]; older binaries
  /// throw `UnsupportedError`.
  bool get supportsXa => _native.supportsXa;

  /// Internal â€” exposes the underlying [bindings.OdbcNative] to
  /// helpers like [XaTransactionHandle] that need to drive the FFI
  /// directly. Not part of the public API; callers should use the
  /// high-level methods on this class.
  bindings.OdbcNative get native => _native;

  // -----------------------------------------------------------------
  // Sprint 4.3 â€” XA / 2PC distributed transactions.
  //
  // High-level wrappers that convert between native return codes and
  // the [XaTransactionHandle] state-machine helper. The lower-level
  // FFI is available via [native] for callers that need the raw
  // integer results.
  // -----------------------------------------------------------------

  /// `xa_start`: open a new XA branch on [connectionId] with the
  /// given [xid]. Returns a live [XaTransactionHandle] in the
  /// [XaState.active] state on success, `null` on failure (call
  /// [getStructuredError] to inspect the cause).
  ///
  /// Drive Phase 2 with [XaTransactionHandle.end] â†’
  /// [XaTransactionHandle.prepare] â†’ [XaTransactionHandle.commitPrepared]
  /// or [XaTransactionHandle.rollbackPrepared]. Single-RM callers can
  /// use the [XaTransactionHandle.commitOnePhase] shortcut.
  XaTransactionHandle? xaStart(int connectionId, Xid xid) {
    final xaId = _native.xaStart(
      connectionId: connectionId,
      formatId: xid.formatId,
      gtrid: xid.gtrid,
      bqual: xid.bqual,
    );
    if (xaId == 0) return null;
    return createNativeXaTransactionHandle(
      xaId: xaId,
      xid: xid,
      conn: _connection,
    );
  }

  /// `xa_recover`: list every XID currently in the [XaState.prepared]
  /// state on the resource manager. Used after process restart to
  /// discover branches awaiting a Phase 2 decision.
  ///
  /// Resume each XID with [xaResumePrepared] and call
  /// [XaTransactionHandle.commitPrepared] / [XaTransactionHandle.rollbackPrepared]
  /// per the Transaction Manager's recovery decision.
  ///
  /// Returns an empty list when no prepared XIDs exist; returns
  /// `null` on FFI failure (call [getStructuredErrorForConnection]).
  List<Xid>? xaRecover(int connectionId) {
    final count = _native.xaRecoverCount(connectionId);
    if (count < 0) return null;
    final out = <Xid>[];
    for (var i = 0; i < count; i++) {
      final entry = _native.xaRecoverGet(i);
      if (entry == null) continue;
      // Skip malformed neighbours that violated X/Open length limits
      // instead of aborting recovery for every prepared branch.
      if (entry.gtrid.isEmpty ||
          entry.gtrid.length > 64 ||
          entry.bqual.length > 64) {
        continue;
      }
      out.add(
        Xid(
          formatId: entry.formatId,
          gtrid: entry.gtrid,
          bqual: entry.bqual,
        ),
      );
    }
    return out;
  }

  /// Resume a previously prepared [xid] â€” rebuilds an
  /// [XaTransactionHandle] in the [XaState.prepared] state for crash-
  /// recovery scenarios. Returns `null` on failure.
  XaTransactionHandle? xaResumePrepared(int connectionId, Xid xid) {
    final xaId = _native.xaResumePrepared(
      connectionId: connectionId,
      formatId: xid.formatId,
      gtrid: xid.gtrid,
      bqual: xid.bqual,
    );
    if (xaId == 0) return null;
    return createNativeXaTransactionHandle(
      xaId: xaId,
      xid: xid,
      conn: _connection,
      initialState: XaState.prepared,
    );
  }

  bool commitTransaction(int txnId) => _native.transactionCommit(txnId);

  bool rollbackTransaction(int txnId) => _native.transactionRollback(txnId);

  bool createSavepoint(int txnId, String name) =>
      _native.savepointCreate(txnId, name);

  bool rollbackToSavepoint(int txnId, String name) =>
      _native.savepointRollback(txnId, name);

  bool releaseSavepoint(int txnId, String name) =>
      _native.savepointRelease(txnId, name);
}
