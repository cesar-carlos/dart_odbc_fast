part of 'message_protocol.dart';

class ExecuteQueryParamsRequest extends WorkerRequest {
  const ExecuteQueryParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    this.serializedParams, {
    this.maxResultBufferBytes,
    this.resultEncoding = ResultEncoding.rowMajor,
  }) : super(requestId, RequestType.executeQueryParams);
  final int connectionId;
  final String sql;
  final Uint8List serializedParams;
  final int? maxResultBufferBytes;
  final ResultEncoding resultEncoding;
}

/// Execute query returning multiple result sets.
class ExecuteQueryMultiRequest extends WorkerRequest {
  const ExecuteQueryMultiRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.maxResultBufferBytes,
  }) : super(requestId, RequestType.executeQueryMulti);
  final int connectionId;
  final String sql;
  final int? maxResultBufferBytes;
}

/// Execute parameterised multi-result query (M5 in v3.2.0).
class ExecuteQueryMultiParamsRequest extends WorkerRequest {
  const ExecuteQueryMultiParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    this.serializedParams, {
    this.maxResultBufferBytes,
  }) : super(requestId, RequestType.executeQueryMultiParams);
  final int connectionId;
  final String sql;
  final Uint8List serializedParams;
  final int? maxResultBufferBytes;
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
  const ExecutePreparedRequest(
    int requestId,
    this.stmtId,
    this.serializedParams, {
    this.timeoutOverrideMs = 0,
    this.fetchSize = 1000,
    this.maxResultBufferBytes,
  }) : super(requestId, RequestType.executePrepared);
  final int stmtId;
  final Uint8List serializedParams;
  final int timeoutOverrideMs;
  final int fetchSize;
  final int? maxResultBufferBytes;
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
  }) : super(requestId, RequestType.catalogTables);
  final int connectionId;
  final String catalog;
  final String schema;
}

/// Catalog columns.
class CatalogColumnsRequest extends WorkerRequest {
  const CatalogColumnsRequest(int requestId, this.connectionId, this.table)
      : super(requestId, RequestType.catalogColumns);
  final int connectionId;
  final String table;
}

/// Catalog type info.
class CatalogTypeInfoRequest extends WorkerRequest {
  const CatalogTypeInfoRequest(int requestId, this.connectionId)
      : super(requestId, RequestType.catalogTypeInfo);
  final int connectionId;
}

/// Catalog primary keys.
class CatalogPrimaryKeysRequest extends WorkerRequest {
  const CatalogPrimaryKeysRequest(int requestId, this.connectionId, this.table)
      : super(requestId, RequestType.catalogPrimaryKeys);
  final int connectionId;
  final String table;
}

/// Catalog foreign keys.
class CatalogForeignKeysRequest extends WorkerRequest {
  const CatalogForeignKeysRequest(int requestId, this.connectionId, this.table)
      : super(requestId, RequestType.catalogForeignKeys);
  final int connectionId;
  final String table;
}

/// Catalog indexes.
class CatalogIndexesRequest extends WorkerRequest {
  const CatalogIndexesRequest(int requestId, this.connectionId, this.table)
      : super(requestId, RequestType.catalogIndexes);
  final int connectionId;
  final String table;
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
  const ExecuteAsyncStartParamsRequest(
    int requestId,
    this.connectionId,
    this.sql,
    this.serializedParams, {
    this.resultEncodingWire = 0,
  }) : super(requestId, RequestType.executeAsyncStartParams);
  final int connectionId;
  final String sql;
  final Uint8List serializedParams;
  final int resultEncodingWire;
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
  }) : super(requestId, RequestType.asyncGetResult);
  final int asyncRequestId;
  final int? maxResultBufferBytes;
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
