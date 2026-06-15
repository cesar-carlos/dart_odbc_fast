import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// Fake worker: initialize handshake fails (success=false).
void fakeWorkerInitFailure(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: false));
    }
  });
}

/// Fake worker: responds to InitializeRequest only, never responds to others.
void fakeWorkerNoResponse(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
    }
  });
}

/// Fake worker: delays query responses without touching a live DSN.
void fakeWorkerDelayedQuery(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) async {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ConnectRequest) {
      mainSendPort
          .send(ConnectResponse(message.requestId, 100000 + message.requestId));
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      await Future<void>.delayed(const Duration(seconds: 1));
      mainSendPort.send(
        QueryResponse(message.requestId, data: Uint8List.fromList([1])),
      );
      return;
    }
    if (message is DisconnectRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
    }
  });
}

/// Fake worker: creates affinities, then exits without replying to query.
void fakeWorkerControlledExit(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ConnectRequest) {
      mainSendPort.send(ConnectResponse(message.requestId, 7001));
      return;
    }
    if (message is PrepareRequest) {
      mainSendPort.send(IntResponse(message.requestId, 8001));
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      return;
    }
  });
}

/// Fake worker: supports prepare/execute paths used by named-params tests.
void fakeWorkerNamedSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is PrepareRequest) {
      final hasNamedPlaceholder =
          message.sql.contains('@') || message.sql.contains(':');
      mainSendPort.send(
        IntResponse(message.requestId, hasNamedPlaceholder ? 0 : 42),
      );
      return;
    }
    if (message is ExecutePreparedRequest) {
      if (message.serializedParams.isEmpty) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'missing params'),
        );
      } else {
        final params = deserializeParamValues(message.serializedParams);
        mainSendPort.send(
          QueryResponse(
            message.requestId,
            data: Uint8List.fromList([params.length]),
          ),
        );
      }
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      final hasNamedPlaceholder =
          message.sql.contains('@') || message.sql.contains(':');
      if (hasNamedPlaceholder) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'named placeholders leaked'),
        );
      } else if (message.serializedParams.isEmpty) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'missing params'),
        );
      } else {
        final params = deserializeParamValues(message.serializedParams);
        mainSendPort.send(
          QueryResponse(
            message.requestId,
            data: Uint8List.fromList([params.length]),
          ),
        );
      }
      return;
    }
    if (message is CloseStatementRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is ClearAllStatementsRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
  });
}

/// Fake worker: supports structured error requests, including per-connection.
void fakeWorkerStructuredErrorSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is GetStructuredErrorRequest) {
      mainSendPort.send(
        StructuredErrorResponse(
          message.requestId,
          message: 'global failure',
          sqlStateString: 'HY000',
          nativeCode: 500,
        ),
      );
      return;
    }
    if (message is GetStructuredErrorForConnectionRequest) {
      mainSendPort.send(
        StructuredErrorResponse(
          message.requestId,
          message: 'connection failure ${message.connectionId}',
          sqlStateString: '08S01',
          nativeCode: 701,
        ),
      );
      return;
    }
  });
}

/// Fake worker: supports low-level stream start/fetch/close requests.
void fakeWorkerStreamingSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  var fetched = false;
  final payload = createStreamTestBuffer();

  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is StreamStartRequest) {
      mainSendPort.send(IntResponse(message.requestId, 501));
      return;
    }
    if (message is StreamStartBatchedRequest) {
      mainSendPort.send(IntResponse(message.requestId, 502));
      return;
    }
    if (message is StreamFetchRequest) {
      if (!fetched) {
        fetched = true;
        mainSendPort.send(
          StreamFetchResponse(
            message.requestId,
            success: true,
            data: payload,
          ),
        );
      } else {
        mainSendPort.send(
          StreamFetchResponse(
            message.requestId,
            success: true,
            data: Uint8List(0),
          ),
        );
      }
      return;
    }
    if (message is StreamCloseRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: start streaming always fails with streamId=0.
void fakeWorkerStreamStartFailure(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is StreamStartRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is StreamStartBatchedRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is GetErrorRequest) {
      mainSendPort.send(
        GetErrorResponse(message.requestId, 'stream start failed'),
      );
      return;
    }
    if (message is StreamCloseRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: fetch fails and next start depends on prior close.
void fakeWorkerFetchFailureRequiresClose(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  var streamOpen = false;

  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is StreamStartRequest) {
      if (streamOpen) {
        mainSendPort.send(IntResponse(message.requestId, 0));
      } else {
        streamOpen = true;
        mainSendPort.send(IntResponse(message.requestId, 777));
      }
      return;
    }
    if (message is StreamStartBatchedRequest) {
      if (streamOpen) {
        mainSendPort.send(IntResponse(message.requestId, 0));
      } else {
        streamOpen = true;
        mainSendPort.send(IntResponse(message.requestId, 777));
      }
      return;
    }
    if (message is StreamFetchRequest) {
      mainSendPort.send(
        StreamFetchResponse(
          message.requestId,
          success: false,
          error: 'fetch failed',
        ),
      );
      return;
    }
    if (message is StreamCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is StreamCloseRequest) {
      streamOpen = false;
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is GetErrorRequest) {
      final msg = streamOpen ? 'stream still open' : 'No error';
      mainSendPort.send(GetErrorResponse(message.requestId, msg));
      return;
    }
  });
}

/// Fake worker: instant init/connect/version for stats and guard tests.
void fakeWorkerFastLifecycle(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ConnectRequest) {
      if (message.connectionString.contains('fail')) {
        mainSendPort.send(
          ConnectResponse(message.requestId, 0, error: 'login denied'),
        );
      } else {
        mainSendPort.send(
          ConnectResponse(message.requestId, 10 + message.requestId),
        );
      }
      return;
    }
    if (message is GetVersionRequest) {
      mainSendPort.send(
        VersionResponse(message.requestId, api: 'test-api', abi: 'test-abi'),
      );
      return;
    }
    if (message is DisconnectRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
    }
  });
}

/// Fake worker: supports bulk insert requests.
void fakeWorkerBulkSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is BulkInsertParallelRequest) {
      mainSendPort.send(IntResponse(message.requestId, 42));
      return;
    }
    if (message is BulkInsertArrayRequest) {
      mainSendPort.send(IntResponse(message.requestId, 10));
      return;
    }
  });
}

/// Fake worker: supports cancel statement request.
void fakeWorkerCancelSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is CancelStatementRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: false));
      return;
    }
  });
}

/// Fake worker: supports audit requests.
void fakeWorkerAuditSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  var enabled = false;
  const payload = '[{"event_type":"query","timestamp_ms":1}]';
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is AuditEnableRequest) {
      enabled = message.enabled;
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AuditGetEventsRequest) {
      mainSendPort.send(
        AuditPayloadResponse(message.requestId, payload: payload),
      );
      return;
    }
    if (message is AuditGetStatusRequest) {
      final status = '{"enabled":$enabled,"event_count":1}';
      mainSendPort.send(
        AuditPayloadResponse(message.requestId, payload: status),
      );
      return;
    }
    if (message is AuditClearRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: returns 4 "pending" polls before returning "ready".
/// Used to verify that adaptive backoff terminates correctly.
void fakeWorkerPendingThenReady(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  var pollCount = 0;
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartRequest) {
      mainSendPort.send(IntResponse(message.requestId, 9999));
      return;
    }
    if (message is AsyncPollRequest) {
      pollCount++;
      // Pending for first 4 polls, then ready.
      final status = pollCount <= 4 ? 0 : 1;
      mainSendPort.send(IntResponse(message.requestId, status));
      return;
    }
    if (message is AsyncGetResultRequest) {
      mainSendPort.send(
        QueryResponse(message.requestId, data: Uint8List.fromList([42])),
      );
      return;
    }
    if (message is AsyncCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AsyncFreeRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: supports async execute lifecycle requests.
void fakeWorkerAsyncExecuteSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartRequest) {
      mainSendPort.send(IntResponse(message.requestId, 1234));
      return;
    }
    if (message is AsyncPollRequest) {
      mainSendPort.send(IntResponse(message.requestId, 1)); // ready
      return;
    }
    if (message is AsyncGetResultRequest) {
      mainSendPort.send(
        QueryResponse(message.requestId, data: Uint8List.fromList([1, 2, 3])),
      );
      return;
    }
    if (message is AsyncCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AsyncFreeRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: supports async execute with serialized parameter buffers.
void fakeWorkerAsyncExecuteParamsSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  var paramsLength = 0;
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      paramsLength = message.serializedParams.length;
      mainSendPort.send(IntResponse(message.requestId, 4321));
      return;
    }
    if (message is AsyncPollRequest) {
      mainSendPort.send(IntResponse(message.requestId, 1));
      return;
    }
    if (message is AsyncGetResultRequest) {
      mainSendPort.send(
        QueryResponse(
          message.requestId,
          data: Uint8List.fromList([paramsLength]),
        ),
      );
      return;
    }
    if (message is AsyncFreeRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AsyncCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: async params with non-default
/// [ExecuteAsyncStartParamsRequest.resultEncodingWire].
void fakeWorkerAsyncExecuteParamsColumnarSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  var paramsLength = 0;
  var encodingWire = 0;
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      paramsLength = message.serializedParams.length;
      encodingWire = message.resultEncodingWire;
      mainSendPort.send(IntResponse(message.requestId, 4321));
      return;
    }
    if (message is AsyncPollRequest) {
      mainSendPort.send(IntResponse(message.requestId, 1));
      return;
    }
    if (message is AsyncGetResultRequest) {
      mainSendPort.send(
        QueryResponse(
          message.requestId,
          data: Uint8List.fromList([paramsLength, encodingWire]),
        ),
      );
      return;
    }
    if (message is AsyncFreeRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AsyncCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: reports async params unavailable so callers use fallback.
void fakeWorkerAsyncExecuteParamsFallback(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      mainSendPort.send(
        QueryResponse(message.requestId, data: Uint8List.fromList([9])),
      );
      return;
    }
  });
}

/// Fake worker: delayed connections for worker-pool routing tests.
void fakeWorkerPoolRoutingSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  final localConnections = <int>{};
  receivePort.listen((message) async {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ConnectRequest) {
      final delay = message.connectionString.contains('slow')
          ? const Duration(milliseconds: 240)
          : const Duration(milliseconds: 120);
      await Future<void>.delayed(delay);
      final connectionId = 1000 + message.requestId;
      localConnections.add(connectionId);
      mainSendPort.send(ConnectResponse(message.requestId, connectionId));
      return;
    }
    if (message is ExecuteAsyncStartParamsRequest) {
      mainSendPort.send(IntResponse(message.requestId, 0));
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      if (localConnections.contains(message.connectionId)) {
        mainSendPort.send(
          QueryResponse(message.requestId, data: Uint8List.fromList([1])),
        );
      } else {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'wrong worker'),
        );
      }
      return;
    }
    if (message is DisconnectRequest) {
      localConnections.remove(message.connectionId);
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: async execute stays pending for 2 polls, then ready.
void fakeWorkerAsyncExecuteDelayedReady(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  final pollsByRequest = <int, int>{};
  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ExecuteAsyncStartRequest) {
      pollsByRequest[9001] = 0;
      mainSendPort.send(IntResponse(message.requestId, 9001));
      return;
    }
    if (message is AsyncPollRequest) {
      final count = (pollsByRequest[message.asyncRequestId] ?? 0) + 1;
      pollsByRequest[message.asyncRequestId] = count;
      final status = count >= 3 ? 1 : 0;
      mainSendPort.send(IntResponse(message.requestId, status));
      return;
    }
    if (message is AsyncGetResultRequest) {
      mainSendPort.send(
        QueryResponse(message.requestId, data: Uint8List.fromList([7, 8, 9])),
      );
      return;
    }
    if (message is AsyncCancelRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
    if (message is AsyncFreeRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

/// Fake worker: supports async stream lifecycle requests.
void fakeWorkerAsyncStreamSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final payload = createStreamTestBuffer();
  var pollCount = 0;
  var fetched = false;

  receivePort.listen((message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is StreamStartAsyncRequest) {
      pollCount = 0;
      fetched = false;
      mainSendPort.send(IntResponse(message.requestId, 601));
      return;
    }
    if (message is StreamPollAsyncRequest) {
      pollCount++;
      if (pollCount < 3) {
        mainSendPort.send(IntResponse(message.requestId, 0)); // pending
      } else if (pollCount == 3) {
        mainSendPort.send(IntResponse(message.requestId, 1)); // ready
      } else {
        mainSendPort.send(IntResponse(message.requestId, 2)); // done
      }
      return;
    }
    if (message is StreamFetchRequest) {
      if (!fetched) {
        fetched = true;
        mainSendPort.send(
          StreamFetchResponse(
            message.requestId,
            success: true,
            data: payload,
          ),
        );
      } else {
        mainSendPort.send(
          StreamFetchResponse(
            message.requestId,
            success: true,
            data: Uint8List(0),
          ),
        );
      }
      return;
    }
    if (message is StreamCloseRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

Uint8List createStreamTestBuffer() {
  final bytes = <int>[];

  const magic = 0x4F444243;
  const version = 1;
  const columnCount = 1;
  const rowCount = 1;
  const odbcInteger = 2;
  const columnName = 'id';

  // payload = metadata(2+2+2) + row(1+4+4)
  const payloadSize = 15;

  bytes
    ..addAll(magic.toBytes(4))
    ..addAll(version.toBytes(2))
    ..addAll(columnCount.toBytes(2))
    ..addAll(rowCount.toBytes(4))
    ..addAll(payloadSize.toBytes(4))
    ..addAll(odbcInteger.toBytes(2))
    ..addAll(columnName.length.toBytes(2))
    ..addAll(columnName.codeUnits)
    ..add(0) // not null
    ..addAll(4.toBytes(4)) // int32 length
    ..addAll(1.toBytes(4)); // value = 1

  return Uint8List.fromList(bytes);
}

extension on int {
  List<int> toBytes(int length) {
    final out = <int>[];
    for (var i = 0; i < length; i++) {
      out.add((this >> (i * 8)) & 0xFF);
    }
    return out;
  }
}
