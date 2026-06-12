part of 'async_native_odbc_connection.dart';

mixin _AsyncPool on _AsyncOdbcState, _AsyncWorkerDispatch {
  /// Creates a connection pool in the worker. Returns pool ID on success.
  Future<int> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) async {
    final r = await _sendRequest<IntResponse>(
      PoolCreateRequest(
        _nextRequestId(),
        connectionString,
        maxSize,
        optionsJson: options?.toJson(),
      ),
    );
    return r.value;
  }

  /// Obtains a connection from pool [poolId]. Returns connection ID on success.
  Future<int> poolGetConnection(int poolId) async {
    final r = await _sendRequest<IntResponse>(
      PoolGetConnectionRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns [connectionId] to its pool.
  Future<bool> poolReleaseConnection(int connectionId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolReleaseConnectionRequest(_nextRequestId(), connectionId),
    );
    return r.value;
  }

  /// Runs a health check on pool [poolId].
  Future<bool> poolHealthCheck(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolHealthCheckRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Returns the current state (size, idle) of pool [poolId],
  /// or `null` on error.
  Future<({int size, int idle})?> poolGetState(int poolId) async {
    final r = await _sendRequest<PoolStateResponse>(
      PoolGetStateRequest(_nextRequestId(), poolId),
    );
    if (r.error != null || r.size == null) return null;
    return (size: r.size!, idle: r.idle ?? 0);
  }

  /// Returns detailed pool state payload as JSON, or null on failure.
  Future<String?> poolGetStateJson(int poolId) async {
    final r = await _sendRequest<AuditPayloadResponse>(
      PoolGetStateJsonRequest(_nextRequestId(), poolId),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Resizes pool [poolId] to [newMaxSize] in the worker.
  Future<bool> poolSetSize(int poolId, int newMaxSize) async {
    final r = await _sendRequest<BoolResponse>(
      PoolSetSizeRequest(_nextRequestId(), poolId, newMaxSize),
    );
    return r.value;
  }

  /// Closes pool [poolId] in the worker.
  Future<bool> poolClose(int poolId) async {
    final r = await _sendRequest<BoolResponse>(
      PoolCloseRequest(_nextRequestId(), poolId),
    );
    return r.value;
  }

  /// Performs bulk insert on [connectionId]: [table], [columns], [dataBuffer],
  /// [rowCount]. Returns rows inserted, or negative on error.
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertArrayRequest(
        _nextRequestId(),
        connectionId,
        table,
        columns,
        dataBuffer,
        rowCount,
      ),
    );
    return r.value;
  }

  /// Performs parallel bulk insert on [poolId]. Returns rows inserted,
  /// or negative value on error.
  Future<int> bulkInsertParallel(
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) async {
    final r = await _sendRequest<IntResponse>(
      BulkInsertParallelRequest(
        _nextRequestId(),
        poolId,
        table,
        columns,
        dataBuffer,
        parallelism,
      ),
    );
    return r.value;
  }

  /// Returns engine version (api + abi) for compatibility checks.
  Future<Map<String, String>?> getVersion() async {
    final r = await _sendRequest<VersionResponse>(
      GetVersionRequest(_nextRequestId()),
    );
    if (r.api.isEmpty && r.abi.isEmpty) return null;
    return {'api': r.api, 'abi': r.abi};
  }

  /// Returns ODBC metrics from the worker (query count, errors, latency, etc.).
  Future<OdbcMetrics?> getMetrics() async {
    final r = await _sendRequest<MetricsResponse>(
      GetMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return OdbcMetrics(
      queryCount: r.queryCount,
      errorCount: r.errorCount,
      uptimeSecs: r.uptimeSecs,
      totalLatencyMillis: r.totalLatencyMillis,
      avgLatencyMillis: r.avgLatencyMillis,
    );
  }

  /// Returns prepared statement cache metrics from the worker.
  Future<PreparedStatementMetrics?> getCacheMetrics() async {
    final r = await _sendRequest<CacheMetricsResponse>(
      GetCacheMetricsRequest(_nextRequestId()),
    );
    if (r.error != null) return null;
    return PreparedStatementMetrics(
      cacheSize: r.cacheSize,
      cacheMaxSize: r.cacheMaxSize,
      cacheHits: r.cacheHits,
      cacheMisses: r.cacheMisses,
      totalPrepares: r.totalPrepares,
      totalExecutions: r.totalExecutions,
      memoryUsageBytes: r.memoryUsageBytes,
      avgExecutionsPerStmt: r.avgExecutionsPerStmt,
    );
  }

  /// Clears the prepared statement cache in the worker.
  Future<bool> clearStatementCache() async {
    final r = await _sendRequest<ClearCacheResponse>(
      ClearCacheRequest(_nextRequestId()),
    );
    return r.error == null;
  }

  /// Enables metadata cache in the worker.
  Future<bool> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    final r = await _sendRequest<BoolResponse>(
      MetadataCacheEnableRequest(
        _nextRequestId(),
        maxEntries: maxEntries,
        ttlSeconds: ttlSeconds,
      ),
    );
    return r.value;
  }

  /// Returns metadata cache stats as JSON payload, or null on failure.
  Future<String?> getMetadataCacheStatsJson() async {
    final r = await _sendRequest<AuditPayloadResponse>(
      MetadataCacheStatsRequest(_nextRequestId()),
    );
    if (r.error != null) {
      return null;
    }
    return r.payload;
  }

  /// Clears metadata cache entries in the worker.
  Future<bool> clearMetadataCache() async {
    final r = await _sendRequest<BoolResponse>(
      MetadataCacheClearRequest(_nextRequestId()),
    );
    return r.value;
  }
}
