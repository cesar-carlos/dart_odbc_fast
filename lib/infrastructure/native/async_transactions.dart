part of 'async_native_odbc_connection.dart';

mixin _AsyncTransactions on _AsyncOdbcState, _AsyncWorkerDispatch {
  /// Starts a transaction in the worker for [connectionId] with
  /// [isolationLevel]. Returns the transaction ID on success.
  ///
  /// [savepointDialect] is the wire code from `SavepointDialect.code`
  /// (default `0` = `auto`, resolved by the Rust engine via SQLGetInfo).
  /// [accessMode] is the wire code from `TransactionAccessMode.code`
  /// (default `0` = `readWrite`). Sprint 4.1.
  /// [lockTimeoutMs] is the per-transaction lock timeout in milliseconds
  /// (default `0` = engine default). Sprint 4.2.
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async {
    final r = await _sendRequest<IntResponse>(
      BeginTransactionRequest(
        _nextRequestId(),
        connectionId,
        isolationLevel,
        savepointDialect: savepointDialect,
        accessMode: accessMode,
        lockTimeoutMs: lockTimeoutMs,
      ),
    );
    return r.value;
  }

  /// Commits the transaction identified by [txnId] in the worker.
  Future<bool> commitTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      CommitTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Rolls back the transaction identified by [txnId] in the worker.
  Future<bool> rollbackTransaction(int txnId) async {
    final r = await _sendRequest<BoolResponse>(
      RollbackTransactionRequest(_nextRequestId(), txnId),
    );
    return r.value;
  }

  /// Creates a savepoint [name] within the transaction [txnId] in the worker.
  Future<bool> createSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointCreateRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Rolls back to savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> rollbackToSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointRollbackRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Releases savepoint [name] in transaction [txnId].
  /// Transaction stays active.
  Future<bool> releaseSavepoint(int txnId, String name) async {
    final r = await _sendRequest<BoolResponse>(
      SavepointReleaseRequest(_nextRequestId(), txnId, name),
    );
    return r.value;
  }

  /// Starts an XA branch; returns native `xa_id` or `0` on failure.
  Future<int> xaStart(int connectionId, Xid xid) async {
    final r = await _sendRequest<IntResponse>(
      XaStartRequest(
        _nextRequestId(),
        connectionId,
        formatId: xid.formatId,
        gtrid: xid.gtrid,
        bqual: xid.bqual,
      ),
    );
    return r.value;
  }

  Future<int> xaEnd(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaEnd, xaId),
    );
    return r.value;
  }

  Future<int> xaPrepare(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaPrepare, xaId),
    );
    return r.value;
  }

  Future<int> xaCommitPrepared(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaCommitPrepared, xaId),
    );
    return r.value;
  }

  Future<int> xaRollbackPrepared(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaRollbackPrepared, xaId),
    );
    return r.value;
  }

  Future<int> xaCommitOnePhase(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaCommitOnePhase, xaId),
    );
    return r.value;
  }

  Future<int> xaRollbackActive(int xaId) async {
    final r = await _sendRequest<IntResponse>(
      XaIdRequest(_nextRequestId(), RequestType.xaRollbackActive, xaId),
    );
    return r.value;
  }

  /// Recovers prepared XIDs; returns `null` on FFI failure.
  Future<List<Xid>?> xaRecover(int connectionId) async {
    final r = await _sendRequest<XaRecoverResponse>(
      XaRecoverRequest(_nextRequestId(), connectionId),
    );
    if (r.error != null) return null;
    return [
      for (final entry in r.entries)
        Xid(
          formatId: entry.formatId,
          gtrid: entry.gtrid,
          bqual: entry.bqual,
        ),
    ];
  }

  /// Resumes a prepared XID; returns native `xa_id` or `0` on failure.
  Future<int> xaResumePrepared(int connectionId, Xid xid) async {
    final r = await _sendRequest<IntResponse>(
      XaResumePreparedRequest(
        _nextRequestId(),
        connectionId,
        formatId: xid.formatId,
        gtrid: xid.gtrid,
        bqual: xid.bqual,
      ),
    );
    return r.value;
  }
}
