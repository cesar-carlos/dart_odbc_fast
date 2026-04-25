import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('message protocol requests', () {
    test('new endpoint requests carry request type and payload', () {
      const setLogLevel = SetLogLevelRequest(1, 3);
      const capabilities = GetDriverCapabilitiesRequest(2, 'DSN=Fake');
      const dbmsInfo = GetConnectionDbmsInfoRequest(3, 42);
      const poolSetSize = PoolSetSizeRequest(4, 7, 12);
      const clearStatements = ClearAllStatementsRequest(5);

      expect(setLogLevel.type, RequestType.setLogLevel);
      expect(setLogLevel.level, 3);
      expect(capabilities.type, RequestType.getDriverCapabilities);
      expect(capabilities.connectionString, 'DSN=Fake');
      expect(dbmsInfo.type, RequestType.getConnectionDbmsInfo);
      expect(dbmsInfo.connectionId, 42);
      expect(poolSetSize.type, RequestType.poolSetSize);
      expect(poolSetSize.poolId, 7);
      expect(poolSetSize.newMaxSize, 12);
      expect(clearStatements.type, RequestType.clearAllStatements);
    });

    test('stream and prepared requests keep default tuning values', () {
      final params = Uint8List.fromList([1, 2, 3]);
      final executePrepared = ExecutePreparedRequest(10, 11, params);
      const streamStart = StreamStartAsyncRequest(12, 13, 'SELECT 1');
      const multiStart = StreamMultiStartAsyncRequest(14, 15, 'SELECT 2');

      expect(executePrepared.type, RequestType.executePrepared);
      expect(executePrepared.timeoutOverrideMs, isZero);
      expect(executePrepared.fetchSize, 1000);
      expect(executePrepared.maxResultBufferBytes, isNull);
      expect(streamStart.fetchSize, 1000);
      expect(streamStart.chunkSize, 64 * 1024);
      expect(multiStart.chunkSize, 64 * 1024);
    });

    test('requests are sendable across isolate ports', () async {
      final receivePort = ReceivePort();
      final request = ExecuteQueryMultiParamsRequest(
        21,
        22,
        'SELECT ?',
        Uint8List.fromList([9]),
        maxResultBufferBytes: 1024,
      );

      receivePort.sendPort.send(request);
      final message = await receivePort.first as ExecuteQueryMultiParamsRequest;
      receivePort.close();

      expect(message.requestId, 21);
      expect(message.connectionId, 22);
      expect(message.type, RequestType.executeQueryMultiParams);
      expect(message.serializedParams, [9]);
      expect(message.maxResultBufferBytes, 1024);
    });
  });

  group('message protocol responses', () {
    test('responses carry request id and payload fields', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final responses = <WorkerResponse>[
        const InitializeResponse(1, success: true),
        const ConnectResponse(2, 99),
        const BoolResponse(3, value: true),
        QueryResponse(4, data: data),
        const IntResponse(5, 8),
        const PoolStateResponse(6, size: 4, idle: 2),
        const VersionResponse(7, api: '3.5.4', abi: '1'),
        const GetErrorResponse(8, 'native error'),
        const DetectDriverResponse(9, 'SQLite'),
        const AuditPayloadResponse(10, payload: '{"ok":true}'),
      ];

      expect(responses.map((response) => response.requestId), [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
      ]);
      expect((responses[3] as QueryResponse).data, data);
      expect((responses[5] as PoolStateResponse).idle, 2);
      expect((responses[8] as DetectDriverResponse).driverName, 'SQLite');
    });

    test('responses are sendable across isolate ports', () async {
      final receivePort = ReceivePort();
      const response = StructuredErrorResponse(
        31,
        message: 'syntax error',
        sqlStateString: '42000',
        nativeCode: 102,
      );

      receivePort.sendPort.send(response);
      final message = await receivePort.first as StructuredErrorResponse;
      receivePort.close();

      expect(message.requestId, 31);
      expect(message.message, 'syntax error');
      expect(message.sqlStateString, '42000');
      expect(message.nativeCode, 102);
    });
  });
}
