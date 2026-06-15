part of 'message_protocol.dart';

class StreamStartRequest extends WorkerRequest {
  const StreamStartRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.chunkSize = 1000,
  }) : super(requestId, RequestType.streamStart);
  final int connectionId;
  final String sql;
  final int chunkSize;
}

/// Start low-level batched streaming query.
class StreamStartBatchedRequest extends WorkerRequest {
  const StreamStartBatchedRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.fetchSize = 1000,
    this.chunkSize = 64 * 1024,
    this.resultEncodingWire = 0,
  }) : super(requestId, RequestType.streamStartBatched);
  final int connectionId;
  final String sql;
  final int fetchSize;
  final int chunkSize;

  /// [ResultEncoding.wireCode]; 0 = row-major (default).
  final int resultEncodingWire;
}

/// Start low-level async batched streaming query.
class StreamStartAsyncRequest extends WorkerRequest {
  const StreamStartAsyncRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.fetchSize = 1000,
    this.chunkSize = 64 * 1024,
    this.resultEncodingWire = 0,
  }) : super(requestId, RequestType.streamStartAsync);
  final int connectionId;
  final String sql;
  final int fetchSize;
  final int chunkSize;

  /// [ResultEncoding.wireCode]; 0 = row-major (default).
  final int resultEncodingWire;
}

/// Start streaming multi-result batch (M8 in v3.3.0).
class StreamMultiStartBatchedRequest extends WorkerRequest {
  const StreamMultiStartBatchedRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.fetchSize = 1000,
    this.chunkSize = 64 * 1024,
    this.resultEncodingWire = 0,
  }) : super(requestId, RequestType.streamMultiStartBatched);
  final int connectionId;
  final String sql;
  final int fetchSize;
  final int chunkSize;

  /// [ResultEncoding.wireCode]; 0 = row-major (default).
  final int resultEncodingWire;
}

/// Start async streaming multi-result batch (M8 in v3.3.0).
class StreamMultiStartAsyncRequest extends WorkerRequest {
  const StreamMultiStartAsyncRequest(
    int requestId,
    this.connectionId,
    this.sql, {
    this.fetchSize = 1000,
    this.chunkSize = 64 * 1024,
    this.resultEncodingWire = 0,
  }) : super(requestId, RequestType.streamMultiStartAsync);
  final int connectionId;
  final String sql;
  final int fetchSize;
  final int chunkSize;

  /// [ResultEncoding.wireCode]; 0 = row-major (default).
  final int resultEncodingWire;
}

/// Poll async stream status.
class StreamPollAsyncRequest extends WorkerRequest {
  const StreamPollAsyncRequest(int requestId, this.streamId)
      : super(requestId, RequestType.streamPollAsync);
  final int streamId;
}

/// Fetch next chunk from an active stream.
class StreamFetchRequest extends WorkerRequest {
  const StreamFetchRequest(int requestId, this.streamId)
      : super(requestId, RequestType.streamFetch);
  final int streamId;
}

/// Cancel active stream.
class StreamCancelRequest extends WorkerRequest {
  const StreamCancelRequest(int requestId, this.streamId)
      : super(requestId, RequestType.streamCancel);
  final int streamId;
}

/// Close active stream.
class StreamCloseRequest extends WorkerRequest {
  const StreamCloseRequest(int requestId, this.streamId)
      : super(requestId, RequestType.streamClose);
  final int streamId;
}

/// Close all prepared statements.
class StreamFetchResponse extends WorkerResponse {
  StreamFetchResponse(
    super.requestId, {
    required this.success,
    Uint8List? data,
    TransferableTypedData? transferableData,
    this.hasMore = false,
    this.error,
  })  : _data = data,
        _transferableData = transferableData;
  final bool success;
  Uint8List? _data;
  final TransferableTypedData? _transferableData;
  final bool hasMore;
  final String? error;

  Uint8List? get data {
    final data = _data;
    if (data != null) {
      return data;
    }
    final transferableData = _transferableData;
    if (transferableData == null) {
      return null;
    }
    return _data = transferableData.materialize().asUint8List();
  }
}
