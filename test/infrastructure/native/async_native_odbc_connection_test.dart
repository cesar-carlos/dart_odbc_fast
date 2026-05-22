import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../helpers/load_env.dart';

/// Fake worker: responds to InitializeRequest only, never responds to others.
void _fakeWorkerNoResponse(SendPort mainSendPort) {
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
void _fakeWorkerDelayedQuery(SendPort mainSendPort) {
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
void _fakeWorkerControlledExit(SendPort mainSendPort) {
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
void _fakeWorkerNamedSupport(SendPort mainSendPort) {
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
void _fakeWorkerStructuredErrorSupport(SendPort mainSendPort) {
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
void _fakeWorkerStreamingSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  var fetched = false;
  final payload = _createStreamTestBuffer();

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
void _fakeWorkerStreamStartFailure(SendPort mainSendPort) {
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
void _fakeWorkerFetchFailureRequiresClose(SendPort mainSendPort) {
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
void _fakeWorkerFastLifecycle(SendPort mainSendPort) {
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
void _fakeWorkerBulkSupport(SendPort mainSendPort) {
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
void _fakeWorkerCancelSupport(SendPort mainSendPort) {
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
void _fakeWorkerAuditSupport(SendPort mainSendPort) {
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

/// Fake worker: supports async execute lifecycle requests.
void _fakeWorkerAsyncExecuteSupport(SendPort mainSendPort) {
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
void _fakeWorkerAsyncExecuteParamsSupport(SendPort mainSendPort) {
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

/// Fake worker: reports async params unavailable so callers use fallback.
void _fakeWorkerAsyncExecuteParamsFallback(SendPort mainSendPort) {
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
void _fakeWorkerPoolRoutingSupport(SendPort mainSendPort) {
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
void _fakeWorkerAsyncExecuteDelayedReady(SendPort mainSendPort) {
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
void _fakeWorkerAsyncStreamSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final payload = _createStreamTestBuffer();
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

Uint8List _createStreamTestBuffer() {
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

void main() {
  loadTestEnv();
  group('AsyncError', () {
    test('should convert to ConnectionError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection failed',
        sqlState: '08001',
        nativeCode: 1,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection failed'));
      expect(odbcError.sqlState, equals('08001'));
      expect(odbcError.nativeCode, equals(1));
    });

    test('should convert to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Query failed',
        sqlState: '42000',
        nativeCode: 102,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Query failed'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(102));
    });

    test('should convert to ValidationError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: 'Invalid parameter',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ValidationError>());
      expect(odbcError.message, equals('Invalid parameter'));
    });

    test('should convert to EnvironmentNotInitializedError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Not initialized',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<EnvironmentNotInitializedError>());
    });

    test('should convert requestTimeout to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.requestTimeout,
        message: 'Worker did not respond within 5s',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Worker did not respond within 5s'));
    });

    test('should convert workerTerminated to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(
        odbcError.message,
        equals('Connection disposed; worker shutting down'),
      );
    });

    test('should convert resourceExhausted to ResourceLimitReachedError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.resourceExhausted,
        message: 'Async worker pool queue is full',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ResourceLimitReachedError>());
      expect(odbcError.message, equals('Async worker pool queue is full'));
    });

    test('should provide readable toString', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Test error',
        sqlState: '08001',
        nativeCode: 1,
      );

      final str = asyncError.toString();

      expect(str, contains('AsyncError'));
      expect(str, contains('connectionFailed'));
      expect(str, contains('Test error'));
      expect(str, contains('SQLSTATE: 08001'));
      expect(str, contains('Native: 1'));
    });
  });

  group('Worker response payloads', () {
    test('QueryResponse supports TransferableTypedData bytes', () {
      final response = QueryResponse(
        1,
        transferableData: TransferableTypedData.fromList([
          Uint8List.fromList([1, 2, 3]),
        ]),
      );

      expect(response.data, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('StreamFetchResponse supports Uint8List bytes', () {
      final bytes = Uint8List.fromList([4, 5, 6]);
      final response = StreamFetchResponse(
        1,
        success: true,
        data: bytes,
      );

      expect(response.data, equals(bytes));
    });
  });

  group('AsyncNativeOdbcConnection', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection();
    });

    test('workerCount defaults to one and rejects invalid values', () {
      expect(async.workerCount, equals(1));
      expect(
        () => AsyncNativeOdbcConnection(workerCount: 0),
        throwsArgumentError,
      );
    });

    test('maxPendingRequests defaults to null and rejects invalid values', () {
      expect(async.maxPendingRequests, isNull);
      expect(async.backpressureMode, equals(AsyncBackpressureMode.failFast));
      expect(async.backpressureTimeout, isNull);
      expect(
        () => AsyncNativeOdbcConnection(maxPendingRequests: 0),
        throwsArgumentError,
      );
      expect(
        () => AsyncNativeOdbcConnection(
          backpressureTimeout: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('should initialize without blocking', () async {
      final stopwatch = Stopwatch()..start();
      await async.initialize();
      stopwatch.stop();

      expect(async.isInitialized, isTrue);
      // Should complete quickly even if ODBC init is slow
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('should return true when already initialized', () async {
      await async.initialize();
      expect(async.isInitialized, isTrue);

      // Second initialize should return true immediately
      final result = await async.initialize();
      expect(result, isTrue);
    });

    test('should throw AsyncError when connecting without initialization',
        () async {
      // Skip initialization
      expect(
        () => async.connect('DSN=Test'),
        throwsA(isA<AsyncError>()),
      );
    });

    test('should throw AsyncError with notInitialized code', () async {
      try {
        await async.connect('DSN=Test');
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.notInitialized));
        expect(e.message, contains('not initialized'));
      }
    });

    test(
      'should not block main thread during long operation',
      () async {
        await async.initialize();

        // Simulate UI thread responsiveness
        final uiResponder = Completer<void>();
        Timer(const Duration(milliseconds: 50), uiResponder.complete);

        // Run operation (even if it takes time)
        // Note: This will fail with invalid DSN but that's ok for the test
        try {
          await async.connect('DSN=InvalidDSNThatMightTimeout');
        } on Exception {
          // Expected - invalid DSN
        }

        // UI should have responded even if connect took time
        await expectLater(uiResponder.future, completes);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'should NOT block main thread while a worker request is pending',
      () async {
        async.dispose();
        async =
            AsyncNativeOdbcConnection(isolateEntry: _fakeWorkerDelayedQuery);
        await async.initialize();
        final connId = await async.connect('DSN=fake');

        final timerCompleted = Completer<void>();
        Timer(const Duration(milliseconds: 100), timerCompleted.complete);

        final queryFuture = async.executeQueryParams(
          connId,
          'SELECT 1',
          [],
        );

        await expectLater(
          timerCompleted.future,
          completes,
          reason: 'Timer should complete before long query finishes',
        );
        await queryFuture;
        await async.disconnect(connId);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'should execute independent queries concurrently across workers',
      () async {
        async.dispose();
        async = AsyncNativeOdbcConnection(
          workerCount: 3,
          isolateEntry: _fakeWorkerDelayedQuery,
        );
        await async.initialize();
        final connId1 = await async.connect('DSN=fake');
        final connId2 = await async.connect('DSN=fake');
        final connId3 = await async.connect('DSN=fake');

        final results = await Future.wait([
          async.executeQueryParams(
            connId1,
            'SELECT 1',
            [],
          ),
          async.executeQueryParams(
            connId2,
            'SELECT 1',
            [],
          ),
          async.executeQueryParams(
            connId3,
            'SELECT 1',
            [],
          ),
        ]);
        final stats = async.getWorkerPoolStats();

        expect(results, everyElement(equals(Uint8List.fromList([1]))));
        expect(stats.workers, hasLength(3));
        expect(
          stats.workers.map((worker) => worker.totalRouted),
          everyElement(greaterThanOrEqualTo(3)),
          reason: 'Each fake query should keep connection affinity on a '
              'different worker; wall-clock timing is covered by stress tests.',
        );
        await async.disconnect(connId1);
        await async.disconnect(connId2);
        await async.disconnect(connId3);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('should handle errors gracefully', () async {
      await async.initialize();

      // Try to get error when there is none
      final error = await async.getError();
      expect(error, isA<String>());

      // Try to disconnect with invalid connection ID
      final result = await async.disconnect(999);
      expect(result, isA<bool>());
    });

    test('should expose streaming methods as Stream', () {
      final stream1 = async.streamQuery(1, 'SELECT 1', chunkSize: 100);
      final stream2 = async.streamQueryBatched(1, 'SELECT 1', fetchSize: 100);

      // Should return Stream objects (not Future)
      expect(stream1, isA<Stream<ParsedRowBuffer>>());
      expect(stream2, isA<Stream<ParsedRowBuffer>>());
    });

    test('should call dispose on underlying connection', () {
      // Dispose should be synchronous and call through to native
      async.dispose();

      // If it didn't throw, it worked
      expect(true, isTrue);
    });

    test('should handle getStructuredError async', () async {
      await async.initialize();

      // Get structured error - may or may not be null depending on ODBC state
      final error = await async.getStructuredError();

      // Just verify it completes successfully and returns the correct type
      expect(error, isA<StructuredError?>());
    });

    test('should handle getStructuredErrorForConnection async', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerStructuredErrorSupport,
      );
      await async.initialize();

      final error = await async.getStructuredErrorForConnection(77);

      expect(error, isNotNull);
      expect(error!.message, equals('connection failure 77'));
      expect(error.sqlStateString, equals('08S01'));
      expect(error.nativeCode, equals(701));
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection worker pool', () {
    test('distributes independent connection requests across workers',
        () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: _fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final stopwatch = Stopwatch()..start();
      await Future.wait([
        async.connect('DSN=fast_a'),
        async.connect('DSN=fast_b'),
      ]);
      stopwatch.stop();

      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(220),
        reason: 'Two 120ms connect requests should run in parallel',
      );
      async.dispose();
    });

    test('spreads sequential connection affinities across workers', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 3,
        isolateEntry: _fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final connections = <int>[];
      try {
        for (var i = 0; i < 3; i++) {
          connections.add(await async.connect('DSN=fast_$i'));
        }

        final stats = async.getWorkerPoolStats();
        expect(
          stats.workers.map((worker) => worker.totalRouted),
          everyElement(greaterThanOrEqualTo(2)),
        );
      } finally {
        for (final connectionId in connections) {
          await async.disconnect(connectionId);
        }
        async.dispose();
      }
    });

    test('preserves connection affinity for subsequent operations', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: _fakeWorkerPoolRoutingSupport,
      );
      await async.initialize();

      final slow = async.connect('DSN=slow');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fastConnectionId = await async.connect('DSN=fast');
      await slow;

      final data = await async.executeQueryParams(
        fastConnectionId,
        'SELECT ?',
        [const ParamValueInt32(1)],
      );

      expect(data, equals(Uint8List.fromList([1])));
      async.dispose();
    });

    test('fails deterministically when maxPendingRequests is exceeded',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: _fakeWorkerNoResponse,
        maxPendingRequests: 1,
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      try {
        await async.connect('DSN=overflow');
        fail('Expected resourceExhausted');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.resourceExhausted));
        expect(e.message, contains('queue is full'));
      } finally {
        async.dispose();
      }

      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('waitForSlot releases queued requests in FIFO order', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: _fakeWorkerPoolRoutingSupport,
        maxPendingRequests: 1,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
      );
      await async.initialize();

      final first = async.connect('DSN=slow');
      final second = async.connect('DSN=fast');
      final ids = await Future.wait([first, second]);

      expect(ids, hasLength(2));
      expect(ids.first, isNot(equals(ids.last)));
      expect(
        async.getWorkerPoolStats().completedRequests,
        greaterThanOrEqualTo(3),
      );
      async.dispose();
    });

    test('waitForSlot reroutes queued independent requests after slot opens',
        () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: _fakeWorkerPoolRoutingSupport,
        maxPendingRequests: 2,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
      );
      await async.initialize();

      final first = async.connect('DSN=slow_a');
      final second = async.connect('DSN=fast_b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final third = async.connect('DSN=fast_c');

      final ids = await Future.wait([first, second, third]);
      final routed = async
          .getWorkerPoolStats()
          .workers
          .map((worker) => worker.totalRouted)
          .toList(growable: false);

      expect(ids.toSet(), hasLength(3));
      expect(
        routed,
        equals([2, 3]),
        reason: 'The queued third connect initially picks worker 0 while both '
            'workers are busy, then should reroute to worker 1 when worker 1 '
            'frees the first slot.',
      );
      async.dispose();
    });

    test('waitForSlot times out with resourceExhausted', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: _fakeWorkerNoResponse,
        maxPendingRequests: 1,
        backpressureMode: AsyncBackpressureMode.waitForSlot,
        backpressureTimeout: const Duration(milliseconds: 30),
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await expectLater(
        async.connect('DSN=queued'),
        throwsA(
          isA<AsyncError>().having(
            (e) => e.code,
            'code',
            AsyncErrorCode.resourceExhausted,
          ),
        ),
      );
      async.dispose();
      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('reports active, pending and routed worker pool stats', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: _fakeWorkerNoResponse,
      );
      await async.initialize();

      final blocked = async.connect('DSN=blocked');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final stats = async.getWorkerPoolStats();

      expect(stats.workerCount, equals(1));
      expect(stats.activeRequests, equals(1));
      expect(stats.pendingRequests, equals(1));
      expect(stats.totalRouted, equals(2));
      expect(stats.timeouts, equals(0));
      expect(stats.workers, hasLength(1));
      expect(stats.workers.single.pendingRequests, equals(1));
      expect(stats.latencyMaxMicros, greaterThanOrEqualTo(0));

      async.dispose();
      await expectLater(blocked, throwsA(isA<AsyncError>()));
    });

    test('reports timeout counter', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(milliseconds: 20),
        isolateEntry: _fakeWorkerNoResponse,
      );
      await async.initialize();

      await expectLater(async.connect('DSN=Test'), throwsA(isA<AsyncError>()));

      final stats = async.getWorkerPoolStats();
      expect(stats.timeouts, equals(1));
      expect(stats.pendingRequests, equals(0));
      async.dispose();
    });

    test('reports fallback to blocking query path', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncExecuteParamsFallback,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        10,
        'SELECT ?',
        Uint8List.fromList([1]),
      );

      expect(data, equals(Uint8List.fromList([9])));
      expect(async.getWorkerPoolStats().fallbacksToBlocking, equals(1));
      async.dispose();
    });

    test('reports cancel and latency metrics', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerCancelSupport,
      );
      await async.initialize();

      final cancelled = await async.cancelStatement(42);

      expect(cancelled, isFalse);
      final stats = async.getWorkerPoolStats();
      expect(stats.cancelAttempts, equals(1));
      expect(stats.cancelUnsupported, equals(1));
      expect(stats.workers.single.latencyMaxMicros, greaterThan(0));
      async.dispose();
    });

    test('controlled worker exit fails pending and clears affinities',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 5),
        isolateEntry: _fakeWorkerControlledExit,
      );
      await async.initialize();

      final connId = await async.connect('DSN=test');
      final stmtId = await async.prepare(connId, 'SELECT 1');
      expect(stmtId, equals(8001));
      expect(async.affinityEntryCountForTesting, greaterThan(0));

      final pending = async.executeQueryParams(
        connId,
        'SELECT 1',
        const <ParamValue>[],
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      async.failWorkerForTesting(0);
      await expectLater(pending, throwsA(isA<AsyncError>()));
      expect(async.affinityEntryCountForTesting, equals(0));
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection timeout', () {
    test(
      'should throw AsyncError with requestTimeout when worker '
      'does not respond',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(milliseconds: 50),
          isolateEntry: _fakeWorkerNoResponse,
        );
        await async.initialize();

        expect(
          () => async.connect('DSN=Test'),
          throwsA(isA<AsyncError>()),
        );

        try {
          await async.connect('DSN=Test');
          fail('Should have thrown AsyncError');
        } on AsyncError catch (e) {
          expect(e.code, equals(AsyncErrorCode.requestTimeout));
          expect(e.message, contains('did not respond'));
        } finally {
          async.dispose();
        }
      },
    );

    test('should allow Duration.zero to disable timeout', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: Duration.zero,
        isolateEntry: _fakeWorkerNoResponse,
      );
      await async.initialize();

      final connectFuture = async.connect('DSN=Test');
      async.dispose();

      expect(
        () => connectFuture,
        throwsA(isA<AsyncError>()),
      );
      try {
        await connectFuture;
        fail('Should have thrown');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.workerTerminated));
      }
    });
  });

  group('AsyncNativeOdbcConnection dispose with pending', () {
    test(
      'should complete pending requests with error when dispose is called',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(seconds: 60),
          isolateEntry: _fakeWorkerNoResponse,
        );
        await async.initialize();

        final connectFuture = async.connect('DSN=Test');
        async.dispose();

        expect(
          () => connectFuture,
          throwsA(isA<AsyncError>()),
        );
        try {
          await connectFuture;
          fail('Should have thrown AsyncError');
        } on AsyncError catch (e) {
          expect(e.code, equals(AsyncErrorCode.workerTerminated));
          expect(e.message, contains('Connection disposed'));
        }
      },
    );
  });

  group('BinaryProtocolParser', () {
    test(
      'should throw FormatException instead of RangeError when '
      'buffer is truncated',
      () {
        final header = Uint8List(BinaryProtocolParser.headerSize);
        ByteData.sublistView(header)
          ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
          ..setUint16(4, 1, Endian.little)
          ..setUint16(6, 0, Endian.little)
          ..setUint32(8, 0, Endian.little)
          ..setUint32(12, 1000, Endian.little);

        expect(
          () => BinaryProtocolParser.parse(header),
          throwsA(isA<FormatException>()),
        );
        try {
          BinaryProtocolParser.parse(header);
          fail('Should have thrown FormatException');
        } on FormatException catch (e) {
          expect(e.message, contains('Buffer too small for payload'));
        }
      },
    );
  });

  group('AsyncNativeOdbcConnection named parameters', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(isolateEntry: _fakeWorkerNamedSupport);
    });

    tearDown(() {
      async.dispose();
    });

    test('should prepare and execute named prepared statement', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id',
        timeoutMs: 250,
      );
      expect(stmtId, equals(42));

      final result = await async.executePreparedNamed(
        stmtId,
        {'id': 1},
        100,
        500,
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('should execute query with named parameters', () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT * FROM users WHERE id = @id',
        {'id': 7},
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(1));
    });

    test('should preserve repeated named placeholders for query execution',
        () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT * FROM users WHERE id = @id OR parent_id = @id',
        {'id': 7},
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(2));
    });

    test('should support more than five named parameters', () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT @a, @b, @c, @d, @e, @f',
        {
          'a': 1,
          'b': 2,
          'c': 3,
          'd': 4,
          'e': 5,
          'f': 6,
        },
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(6));
    });

    test('should throw invalidParameter when named param is missing', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id AND name = :name',
      );
      expect(stmtId, equals(42));

      try {
        await async.executePreparedNamed(stmtId, {'id': 1}, 0, 1000);
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.invalidParameter));
        expect(e.message, contains('Missing required parameters'));
      }
    });

    test('should clear named prepared metadata after clearAllStatements',
        () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id',
      );
      expect(stmtId, equals(42));

      final clearCode = await async.clearAllStatements();
      expect(clearCode, equals(0));

      await expectLater(
        () => async.executePreparedNamed(stmtId, {'id': 1}, 0, 1000),
        throwsA(
          isA<AsyncError>().having(
            (error) => error.message,
            'message',
            contains('prepareNamed'),
          ),
        ),
      );
    });
  });

  group('AsyncNativeOdbcConnection cancellation', () {
    test('cancelStatement should return worker bool response', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerCancelSupport,
      );
      await async.initialize();
      final ok = await async.cancelStatement(42);
      expect(ok, isFalse);
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection audit', () {
    test('should enable/get/clear audit via worker messages', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAuditSupport,
      );
      await async.initialize();

      final enabled = await async.setAuditEnabled(enabled: true);
      final status = await async.getAuditStatusJson();
      final events = await async.getAuditEventsJson(limit: 10);
      final cleared = await async.clearAuditEvents();

      expect(enabled, isTrue);
      expect(status, contains('"enabled":true'));
      expect(events, startsWith('['));
      expect(cleared, isTrue);
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection async execute', () {
    test('should run async execute lifecycle via worker messages', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncExecuteSupport,
      );
      await async.initialize();

      final requestId = await async.executeAsyncStart(1, 'SELECT 1');
      final status = await async.asyncPoll(requestId);
      final data = await async.asyncGetResult(requestId);
      final cancelled = await async.asyncCancel(requestId);
      final freed = await async.asyncFree(requestId);

      expect(requestId, equals(1234));
      expect(status, equals(1));
      expect(data, isNotNull);
      expect(data, isNotEmpty);
      expect(cancelled, isTrue);
      expect(freed, isTrue);

      async.dispose();
    });

    test('executeAsync should poll until ready and return data', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncExecuteDelayedReady,
      );
      await async.initialize();

      final data = await async.executeAsync(
        1,
        'SELECT 1',
        pollInterval: const Duration(milliseconds: 1),
        timeout: const Duration(seconds: 1),
      );

      expect(data, isNotNull);
      expect(data, equals(Uint8List.fromList([7, 8, 9])));
      async.dispose();
    });

    test('executeQueryParamBuffer should use async params lifecycle', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncExecuteParamsSupport,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        1,
        'SELECT ?',
        Uint8List.fromList([1, 2, 3]),
        timeout: const Duration(seconds: 1),
      );

      expect(data, equals(Uint8List.fromList([3])));
      async.dispose();
    });

    test('executeQueryParamBuffer falls back when async params is unavailable',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncExecuteParamsFallback,
      );
      await async.initialize();

      final data = await async.executeQueryParamBuffer(
        1,
        'SELECT ?',
        Uint8List.fromList([1, 2, 3]),
      );

      expect(data, equals(Uint8List.fromList([9])));
      async.dispose();
    });
  });

  group('AsyncError Integration', () {
    test('should preserve all error information across isolate boundary', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Syntax error near SELECT',
        sqlState: '42000',
        nativeCode: 156,
      );

      final odbcError = asyncError.toOdbcError();

      // Verify all information is preserved
      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Syntax error near SELECT'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(156));
    });

    test('should handle error without SQLSTATE or native code', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection timeout',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection timeout'));
      expect(odbcError.sqlState, isNull);
      expect(odbcError.nativeCode, isNull);
    });
  });

  group('AsyncNativeOdbcConnection streaming protocol', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerStreamingSupport,
      );
    });

    tearDown(() {
      async.dispose();
    });

    test('streamQueryBatched should parse streamed native payload', () async {
      await async.initialize();
      final chunks =
          await async.streamQueryBatched(1, 'SELECT 1', fetchSize: 10).toList();

      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));
    });

    test('streamQuery should parse streamed native payload', () async {
      await async.initialize();
      final chunks = await async.streamQuery(1, 'SELECT 1').toList();

      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));
    });
  });

  group('AsyncNativeOdbcConnection async stream', () {
    test('streamAsync should poll and parse streamed native payload', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerAsyncStreamSupport,
      );
      await async.initialize();

      final chunks = await async.streamAsync(1, 'SELECT 1').toList();
      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));

      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection streaming failures', () {
    test('streamQuery should throw AsyncError when stream start fails',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerStreamStartFailure,
      );
      await async.initialize();

      await expectLater(
        () => async.streamQuery(1, 'SELECT 1').toList(),
        throwsA(
          isA<AsyncError>()
              .having((e) => e.code, 'code', AsyncErrorCode.queryFailed)
              .having(
                (e) => e.message,
                'message',
                contains('stream start failed'),
              ),
        ),
      );
      async.dispose();
    });

    test(
      'streamQuery should close failed stream before next start attempt',
      () async {
        final async = AsyncNativeOdbcConnection(
          isolateEntry: _fakeWorkerFetchFailureRequiresClose,
        );
        await async.initialize();

        Future<void> runAndExpectFetchFailure() async {
          await expectLater(
            () => async.streamQuery(1, 'SELECT 1').toList(),
            throwsA(
              isA<AsyncError>()
                  .having((e) => e.code, 'code', AsyncErrorCode.queryFailed)
                  .having(
                    (e) => e.message,
                    'message',
                    contains('fetch failed'),
                  ),
            ),
          );
        }

        await runAndExpectFetchFailure();
        await runAndExpectFetchFailure();
        async.dispose();
      },
    );
  });

  group('AsyncNativeOdbcConnection recovery guards', () {
    test('dispose should not trigger auto-recovery', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerStreamingSupport,
        autoRecoverOnWorkerCrash: true,
      );
      await async.initialize();

      async.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(async.isInitialized, isFalse);
    });

    test('recoverWorker should be safe when called concurrently', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerStreamingSupport,
      );
      await async.initialize();

      await Future.wait([
        async.recoverWorker(),
        async.recoverWorker(),
        async.recoverWorker(),
      ]);

      expect(async.isInitialized, isTrue);
      final chunks = await async.streamQuery(1, 'SELECT 1').toList();
      expect(chunks, isNotEmpty);
      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection bulk insert parallel', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerBulkSupport,
      );
    });

    tearDown(() {
      async.dispose();
    });

    test('bulkInsertParallel should return rows inserted', () async {
      await async.initialize();

      final inserted = await async.bulkInsertParallel(
        1,
        't',
        const ['a'],
        Uint8List.fromList([0, 1, 2, 3]),
        4,
      );

      expect(inserted, equals(42));
    });
  });

  group('AsyncNativeOdbcConnection Wave 6C', () {
    test('should map transactionFailed and prepareFailed to QueryError', () {
      const transaction = AsyncError(
        code: AsyncErrorCode.transactionFailed,
        message: 'commit failed',
        sqlState: '40001',
        nativeCode: 9,
      );
      const prepare = AsyncError(
        code: AsyncErrorCode.prepareFailed,
        message: 'prepare failed',
        sqlState: '42000',
        nativeCode: 10,
      );

      final transactionError = transaction.toOdbcError();
      final prepareError = prepare.toOdbcError();

      expect(transactionError, isA<QueryError>());
      expect(transactionError.message, equals('commit failed'));
      expect(transactionError.sqlState, equals('40001'));
      expect(transactionError.nativeCode, equals(9));

      expect(prepareError, isA<QueryError>());
      expect(prepareError.message, equals('prepare failed'));
      expect(prepareError.sqlState, equals('42000'));
      expect(prepareError.nativeCode, equals(10));
    });

    test('should map worker connect failure to connectionFailed AsyncError',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );
      await async.initialize();

      try {
        await async.connect('DSN=fail');
        fail('Expected AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.connectionFailed));
        expect(e.message, equals('login denied'));
        expect(e.toOdbcError(), isA<ConnectionError>());
      } finally {
        async.dispose();
      }
    });

    test('should not spawn worker isolate before initialize', () {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );

      expect(async.workerIsolateForTesting, isNull);
      expect(async.isInitialized, isFalse);
    });

    test('should expose zeroed pool stats before initialize', () {
      final async = AsyncNativeOdbcConnection(workerCount: 2);
      final stats = async.getWorkerPoolStats();

      expect(stats.workerCount, equals(2));
      expect(stats.workers, isEmpty);
      expect(stats.activeRequests, equals(0));
      expect(stats.pendingRequests, equals(0));
      expect(stats.totalRouted, equals(0));
      expect(stats.completedRequests, equals(0));
      expect(stats.failedRequests, equals(0));
      expect(stats.timeouts, equals(0));
      expect(stats.latencyP95Micros, equals(0));
    });

    test('should throw StateError when routing before initialize', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );

      expect(
        async.getVersion,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not initialized'),
          ),
        ),
      );
    });

    test('should increment completedRequests after successful round trip',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );
      await async.initialize();

      final version = await async.getVersion();
      final stats = async.getWorkerPoolStats();

      expect(version, equals({'api': 'test-api', 'abi': 'test-abi'}));
      expect(stats.completedRequests, greaterThanOrEqualTo(2));
      expect(stats.failedRequests, equals(0));
      expect(stats.timeouts, equals(0));
      expect(stats.latencyMaxMicros, greaterThanOrEqualTo(0));
      async.dispose();
    });

    test('should aggregate per-worker stats after parallel connects', () async {
      final async = AsyncNativeOdbcConnection(
        workerCount: 2,
        isolateEntry: _fakeWorkerFastLifecycle,
      );
      await async.initialize();

      final ids = await Future.wait([
        async.connect('DSN=a'),
        async.connect('DSN=b'),
      ]);
      final stats = async.getWorkerPoolStats();

      expect(ids, hasLength(2));
      expect(stats.workers, hasLength(2));
      expect(
        stats.workers.map((worker) => worker.totalRouted),
        everyElement(greaterThanOrEqualTo(2)),
      );
      expect(stats.totalRouted, greaterThanOrEqualTo(4));
      expect(stats.completedRequests, greaterThanOrEqualTo(4));

      for (final connectionId in ids) {
        await async.disconnect(connectionId);
      }
      async.dispose();
    });

    test('should return stable aggregate p95 between stats snapshots',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );
      await async.initialize();
      await async.getVersion();

      final first = async.getWorkerPoolStats();
      final second = async.getWorkerPoolStats();

      expect(first.latencyP95Micros, equals(second.latencyP95Micros));
      expect(first.queueWaitP95Micros, equals(second.queueWaitP95Micros));
      expect(first.executionP95Micros, equals(second.executionP95Micros));
      async.dispose();
    });

    test('dispose without initialize should be safe', () {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );

      expect(async.dispose, returnsNormally);
      expect(async.isInitialized, isFalse);
    });

    test('should complete pending requests with workerTerminated on dispose',
        () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: const Duration(seconds: 60),
        isolateEntry: _fakeWorkerNoResponse,
      );
      await async.initialize();

      final pending = async.connect('DSN=blocked');
      async.dispose();

      await expectLater(
        pending,
        throwsA(
          isA<AsyncError>()
              .having((e) => e.code, 'code', AsyncErrorCode.workerTerminated)
              .having(
                (e) => e.message,
                'message',
                contains('Connection disposed'),
              ),
        ),
      );
    });

    test('failWorkerForTesting should ignore unknown worker index', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: _fakeWorkerFastLifecycle,
      );
      await async.initialize();

      expect(() => async.failWorkerForTesting(99), returnsNormally);
      expect(async.isInitialized, isTrue);
      async.dispose();
    });
  });
}
