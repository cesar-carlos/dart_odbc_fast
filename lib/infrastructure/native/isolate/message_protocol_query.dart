part of 'message_protocol.dart';

class ExecuteQueryParamsRequest extends WorkerRequest {
  ExecuteQueryParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    Uint8List serializedParams, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
    this.resultEncoding = ResultEncoding.rowMajor,
  })  : _serializedParams = serializedParams,
        _transferableParams = null,
        super(requestId, RequestType.executeQueryParams);

  ExecuteQueryParamsRequest._transferable(
    int requestId,
    this.connectionId,
    this.sql,
    TransferableTypedData transferableParams, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
    this.resultEncoding = ResultEncoding.rowMajor,
  })  : _serializedParams = null,
        _transferableParams = transferableParams,
        super(requestId, RequestType.executeQueryParams);

  factory ExecuteQueryParamsRequest.withSerializedParams(
    int requestId,
    int connectionId,
    String sql,
    Uint8List serializedParams, {
    int? maxResultBufferBytes,
    int? initialResultBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) {
    final transferableParams = transferableIsolatePayload(serializedParams);
    if (transferableParams != null) {
      return ExecuteQueryParamsRequest._transferable(
        requestId,
        connectionId,
        sql,
        transferableParams,
        maxResultBufferBytes: maxResultBufferBytes,
        initialResultBufferBytes: initialResultBufferBytes,
        resultEncoding: resultEncoding,
      );
    }
    return ExecuteQueryParamsRequest(
      requestId,
      connectionId,
      sql,
      serializedParams,
      maxResultBufferBytes: maxResultBufferBytes,
      initialResultBufferBytes: initialResultBufferBytes,
      resultEncoding: resultEncoding,
    );
  }

  Uint8List? _serializedParams;
  final TransferableTypedData? _transferableParams;
  final int connectionId;
  final String sql;
  final int? maxResultBufferBytes;
  final int? initialResultBufferBytes;
  final ResultEncoding resultEncoding;

  Uint8List get serializedParams {
    final inline = _serializedParams;
    if (inline != null) {
      return inline;
    }
    return _serializedParams = _transferableParams!.materialize().asUint8List();
  }
}

/// Execute query returning multiple result sets.
class ExecuteQueryMultiRequest extends WorkerRequest {
  const ExecuteQueryMultiRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  }) : super(requestId, RequestType.executeQueryMulti);
  final int connectionId;
  final String sql;
  final int? maxResultBufferBytes;
  final int? initialResultBufferBytes;
}

/// Execute parameterised multi-result query (M5 in v3.2.0).
class ExecuteQueryMultiParamsRequest extends WorkerRequest {
  ExecuteQueryMultiParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    Uint8List serializedParams, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  })  : _serializedParams = serializedParams,
        _transferableParams = null,
        super(requestId, RequestType.executeQueryMultiParams);

  ExecuteQueryMultiParamsRequest._transferable(
    int requestId,
    this.connectionId,
    this.sql,
    TransferableTypedData transferableParams, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  })  : _serializedParams = null,
        _transferableParams = transferableParams,
        super(requestId, RequestType.executeQueryMultiParams);

  factory ExecuteQueryMultiParamsRequest.withSerializedParams(
    int requestId,
    int connectionId,
    String sql,
    Uint8List serializedParams, {
    int? maxResultBufferBytes,
    int? initialResultBufferBytes,
  }) {
    final transferableParams = transferableIsolatePayload(serializedParams);
    if (transferableParams != null) {
      return ExecuteQueryMultiParamsRequest._transferable(
        requestId,
        connectionId,
        sql,
        transferableParams,
        maxResultBufferBytes: maxResultBufferBytes,
        initialResultBufferBytes: initialResultBufferBytes,
      );
    }
    return ExecuteQueryMultiParamsRequest(
      requestId,
      connectionId,
      sql,
      serializedParams,
      maxResultBufferBytes: maxResultBufferBytes,
      initialResultBufferBytes: initialResultBufferBytes,
    );
  }

  Uint8List? _serializedParams;
  final TransferableTypedData? _transferableParams;
  final int connectionId;
  final String sql;
  final int? maxResultBufferBytes;
  final int? initialResultBufferBytes;

  Uint8List get serializedParams {
    final inline = _serializedParams;
    if (inline != null) {
      return inline;
    }
    return _serializedParams = _transferableParams!.materialize().asUint8List();
  }
}

/// Begin transaction.
class PrepareRequest extends WorkerRequest {
  const PrepareRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.timeoutMs = 0,
  }) : super(requestId, RequestType.prepare);
  final int connectionId;
  final String sql;
  final int timeoutMs;
}

/// Execute prepared statement. Params sent as serialized Uint8List.
class ExecutePreparedRequest extends WorkerRequest {
  ExecutePreparedRequest(
    int requestId,
    this.stmtId,
    Uint8List serializedParams, {
    this.timeoutOverrideMs = 0,
    this.fetchSize = 1000,
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  })  : _serializedParams = serializedParams,
        _transferableParams = null,
        super(requestId, RequestType.executePrepared);

  ExecutePreparedRequest._transferable(
    int requestId,
    this.stmtId,
    TransferableTypedData transferableParams, {
    this.timeoutOverrideMs = 0,
    this.fetchSize = 1000,
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  })  : _serializedParams = null,
        _transferableParams = transferableParams,
        super(requestId, RequestType.executePrepared);

  factory ExecutePreparedRequest.withSerializedParams(
    int requestId,
    int stmtId,
    Uint8List serializedParams, {
    int timeoutOverrideMs = 0,
    int fetchSize = 1000,
    int? maxResultBufferBytes,
    int? initialResultBufferBytes,
  }) {
    final transferableParams = transferableIsolatePayload(serializedParams);
    if (transferableParams != null) {
      return ExecutePreparedRequest._transferable(
        requestId,
        stmtId,
        transferableParams,
        timeoutOverrideMs: timeoutOverrideMs,
        fetchSize: fetchSize,
        maxResultBufferBytes: maxResultBufferBytes,
        initialResultBufferBytes: initialResultBufferBytes,
      );
    }
    return ExecutePreparedRequest(
      requestId,
      stmtId,
      serializedParams,
      timeoutOverrideMs: timeoutOverrideMs,
      fetchSize: fetchSize,
      maxResultBufferBytes: maxResultBufferBytes,
      initialResultBufferBytes: initialResultBufferBytes,
    );
  }

  Uint8List? _serializedParams;
  final TransferableTypedData? _transferableParams;
  final int stmtId;
  final int timeoutOverrideMs;
  final int fetchSize;
  final int? maxResultBufferBytes;
  final int? initialResultBufferBytes;

  Uint8List get serializedParams {
    final inline = _serializedParams;
    if (inline != null) {
      return inline;
    }
    return _serializedParams = _transferableParams!.materialize().asUint8List();
  }
}

/// Cancel prepared statement execution.
class CancelStatementRequest extends WorkerRequest {
  const CancelStatementRequest(int requestId, this.stmtId)
      : super(requestId, RequestType.cancelStatement);
  final int stmtId;
}

/// Close prepared statement.
class CloseStatementRequest extends WorkerRequest {
  const CloseStatementRequest(int requestId, this.stmtId)
      : super(requestId, RequestType.closeStatement);
  final int stmtId;
}

class ClearAllStatementsRequest extends WorkerRequest {
  const ClearAllStatementsRequest(int requestId)
      : super(requestId, RequestType.clearAllStatements);
}

class BulkInsertArrayRequest extends WorkerRequest {
  BulkInsertArrayRequest(
    int requestId,
    this.connectionId,
    this.table,
    this.columns,
    Uint8List dataBuffer,
    this.rowCount,
  )   : _dataBuffer = dataBuffer,
        _transferableData = null,
        super(requestId, RequestType.bulkInsertArray);

  BulkInsertArrayRequest._transferable(
    int requestId,
    this.connectionId,
    this.table,
    this.columns,
    TransferableTypedData transferableData,
    this.rowCount,
  )   : _dataBuffer = null,
        _transferableData = transferableData,
        super(requestId, RequestType.bulkInsertArray);

  factory BulkInsertArrayRequest.withPayload(
    int requestId,
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) {
    final transferableData = transferableIsolatePayload(dataBuffer);
    if (transferableData != null) {
      return BulkInsertArrayRequest._transferable(
        requestId,
        connectionId,
        table,
        columns,
        transferableData,
        rowCount,
      );
    }
    return BulkInsertArrayRequest(
      requestId,
      connectionId,
      table,
      columns,
      dataBuffer,
      rowCount,
    );
  }

  Uint8List? _dataBuffer;
  final TransferableTypedData? _transferableData;
  final int connectionId;
  final String table;
  final List<String> columns;
  final int rowCount;

  Uint8List get dataBuffer {
    final data = _dataBuffer;
    if (data != null) {
      return data;
    }
    return _dataBuffer = _transferableData!.materialize().asUint8List();
  }
}

/// Parallel bulk insert through pool.
class BulkInsertParallelRequest extends WorkerRequest {
  BulkInsertParallelRequest(
    int requestId,
    this.poolId,
    this.table,
    this.columns,
    Uint8List dataBuffer,
    this.parallelism,
  )   : _dataBuffer = dataBuffer,
        _transferableData = null,
        super(requestId, RequestType.bulkInsertParallel);

  BulkInsertParallelRequest._transferable(
    int requestId,
    this.poolId,
    this.table,
    this.columns,
    TransferableTypedData transferableData,
    this.parallelism,
  )   : _dataBuffer = null,
        _transferableData = transferableData,
        super(requestId, RequestType.bulkInsertParallel);

  factory BulkInsertParallelRequest.withPayload(
    int requestId,
    int poolId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int parallelism,
  ) {
    final transferableData = transferableIsolatePayload(dataBuffer);
    if (transferableData != null) {
      return BulkInsertParallelRequest._transferable(
        requestId,
        poolId,
        table,
        columns,
        transferableData,
        parallelism,
      );
    }
    return BulkInsertParallelRequest(
      requestId,
      poolId,
      table,
      columns,
      dataBuffer,
      parallelism,
    );
  }

  Uint8List? _dataBuffer;
  final TransferableTypedData? _transferableData;
  final int poolId;
  final String table;
  final List<String> columns;
  final int parallelism;

  Uint8List get dataBuffer {
    final data = _dataBuffer;
    if (data != null) {
      return data;
    }
    return _dataBuffer = _transferableData!.materialize().asUint8List();
  }
}

class CatalogTablesRequest extends WorkerRequest {
  const CatalogTablesRequest(
    int requestId,
    this.connectionId, {
    this.catalog = '',
    this.schema = '',
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogTables);
  final int connectionId;
  final String catalog;
  final String schema;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

/// Catalog columns.
class CatalogColumnsRequest extends WorkerRequest {
  const CatalogColumnsRequest(
    int requestId,
    this.connectionId,
    this.table, {
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogColumns);
  final int connectionId;
  final String table;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

/// Catalog type info.
class CatalogTypeInfoRequest extends WorkerRequest {
  const CatalogTypeInfoRequest(
    int requestId,
    this.connectionId, {
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogTypeInfo);
  final int connectionId;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

/// Catalog primary keys.
class CatalogPrimaryKeysRequest extends WorkerRequest {
  const CatalogPrimaryKeysRequest(
    int requestId,
    this.connectionId,
    this.table, {
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogPrimaryKeys);
  final int connectionId;
  final String table;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

/// Catalog foreign keys.
class CatalogForeignKeysRequest extends WorkerRequest {
  const CatalogForeignKeysRequest(
    int requestId,
    this.connectionId,
    this.table, {
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogForeignKeys);
  final int connectionId;
  final String table;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

/// Catalog indexes.
class CatalogIndexesRequest extends WorkerRequest {
  const CatalogIndexesRequest(
    int requestId,
    this.connectionId,
    this.table, {
    this.initialBufferBytes,
    this.maxBufferBytes,
  }) : super(requestId, RequestType.catalogIndexes);
  final int connectionId;
  final String table;
  final int? initialBufferBytes;
  final int? maxBufferBytes;
}

class ExecuteAsyncStartRequest extends WorkerRequest {
  const ExecuteAsyncStartRequest(
    int requestId,
    this.connectionId,
    this.sql,
  ) : super(requestId, RequestType.executeAsyncStart);
  final int connectionId;
  final String sql;
}

/// Start non-blocking async execution with serialized parameters.
class ExecuteAsyncStartParamsRequest extends WorkerRequest {
  ExecuteAsyncStartParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    Uint8List serializedParams, {
    this.resultEncodingWire = 0,
  })  : _serializedParams = serializedParams,
        _transferableParams = null,
        super(requestId, RequestType.executeAsyncStartParams);

  ExecuteAsyncStartParamsRequest._transferable(
    int requestId,
    this.connectionId,
    this.sql,
    TransferableTypedData transferableParams, {
    this.resultEncodingWire = 0,
  })  : _serializedParams = null,
        _transferableParams = transferableParams,
        super(requestId, RequestType.executeAsyncStartParams);

  factory ExecuteAsyncStartParamsRequest.withSerializedParams(
    int requestId,
    int connectionId,
    String sql,
    Uint8List serializedParams, {
    int resultEncodingWire = 0,
  }) {
    final transferableParams = transferableIsolatePayload(serializedParams);
    if (transferableParams != null) {
      return ExecuteAsyncStartParamsRequest._transferable(
        requestId,
        connectionId,
        sql,
        transferableParams,
        resultEncodingWire: resultEncodingWire,
      );
    }
    return ExecuteAsyncStartParamsRequest(
      requestId,
      connectionId,
      sql,
      serializedParams,
      resultEncodingWire: resultEncodingWire,
    );
  }

  Uint8List? _serializedParams;
  final TransferableTypedData? _transferableParams;
  final int connectionId;
  final String sql;
  final int resultEncodingWire;

  Uint8List get serializedParams {
    final inline = _serializedParams;
    if (inline != null) {
      return inline;
    }
    return _serializedParams = _transferableParams!.materialize().asUint8List();
  }
}

/// Poll async request status.
class AsyncPollRequest extends WorkerRequest {
  const AsyncPollRequest(int requestId, this.asyncRequestId)
      : super(requestId, RequestType.asyncPoll);
  final int asyncRequestId;
}

/// Retrieve async request result.
class AsyncGetResultRequest extends WorkerRequest {
  const AsyncGetResultRequest(
    int requestId,
    this.asyncRequestId, {
    this.maxResultBufferBytes,
    this.initialResultBufferBytes,
  }) : super(requestId, RequestType.asyncGetResult);
  final int asyncRequestId;
  final int? maxResultBufferBytes;
  final int? initialResultBufferBytes;
}

/// Cancel async request.
class AsyncCancelRequest extends WorkerRequest {
  const AsyncCancelRequest(int requestId, this.asyncRequestId)
      : super(requestId, RequestType.asyncCancel);
  final int asyncRequestId;
}

/// Free async request resources.
class AsyncFreeRequest extends WorkerRequest {
  const AsyncFreeRequest(int requestId, this.asyncRequestId)
      : super(requestId, RequestType.asyncFree);
  final int asyncRequestId;
}
