import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/result_encoding.dart';
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

    test('ExecuteAsyncStartParamsRequest carries result encoding wire code',
        () async {
      final receivePort = ReceivePort();
      final request = ExecuteAsyncStartParamsRequest(
        31,
        2,
        'SELECT 1',
        Uint8List.fromList([1, 2]),
        resultEncodingWire: ResultEncoding.columnarCompressed.wireCode,
      );

      receivePort.sendPort.send(request);
      final message = await receivePort.first as ExecuteAsyncStartParamsRequest;
      receivePort.close();

      expect(message.requestId, 31);
      expect(message.connectionId, 2);
      expect(message.type, RequestType.executeAsyncStartParams);
      expect(message.resultEncodingWire, 2);
      expect(message.serializedParams, [1, 2]);
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
        const VersionResponse(7, api: '3.6.0', abi: '1'),
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

    test('QueryResponse lazily materializes transferable byte payload', () {
      final bytes = Uint8List.fromList([10, 20, 30]);
      final response = QueryResponse(
        1,
        transferableData: TransferableTypedData.fromList([bytes]),
      );

      expect(response.data, bytes);
      expect(identical(response.data, response.data), isTrue);
      expect(response.error, isNull);
    });

    test('BulkInsertArrayRequest keeps inline payload below threshold', () {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes);
      final request = BulkInsertArrayRequest.withPayload(
        1,
        2,
        't',
        const ['c'],
        bytes,
        3,
      );

      expect(request.dataBuffer, bytes);
      expect(identical(request.dataBuffer, request.dataBuffer), isTrue);
    });

    test('BulkInsertArrayRequest uses transferable payload above threshold',
        () {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes + 1);
      final request = BulkInsertArrayRequest.withPayload(
        1,
        2,
        't',
        const ['c'],
        bytes,
        3,
      );

      expect(request.dataBuffer, bytes);
      expect(identical(request.dataBuffer, request.dataBuffer), isTrue);
    });

    test('BulkInsertParallelRequest uses transferable payload above threshold',
        () {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes + 1);
      final request = BulkInsertParallelRequest.withPayload(
        1,
        2,
        't',
        const ['c'],
        bytes,
        4,
      );

      expect(request.dataBuffer, bytes);
      expect(identical(request.dataBuffer, request.dataBuffer), isTrue);
    });

    test('bulk insert requests are sendable across isolate ports', () async {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes + 1);
      final request = BulkInsertArrayRequest.withPayload(
        11,
        22,
        'items',
        const ['id'],
        bytes,
        5,
      );
      final receivePort = ReceivePort();

      receivePort.sendPort.send(request);
      final message = await receivePort.first as BulkInsertArrayRequest;
      receivePort.close();

      expect(message.requestId, 11);
      expect(message.connectionId, 22);
      expect(message.table, 'items');
      expect(message.rowCount, 5);
      expect(message.dataBuffer, bytes);
    });

    test('StreamFetchResponse exposes success, hasMore, and error fields', () {
      final response = StreamFetchResponse(
        2,
        success: false,
        error: 'stream ended',
      );

      expect(response.data, isNull);
      expect(response.success, isFalse);
      expect(response.hasMore, isFalse);
      expect(response.error, 'stream ended');
    });

    test('metrics and cache responses use zeroed defaults', () {
      const metrics = MetricsResponse(3);
      const cache = CacheMetricsResponse(4);
      const cleared = ClearCacheResponse(5);

      expect(metrics.queryCount, isZero);
      expect(metrics.error, isNull);
      expect(cache.avgExecutionsPerStmt, isZero);
      expect(cache.error, isNull);
      expect(cleared.error, isNull);
    });

    test('ValidateConnectionStringResponse models invalid native validation',
        () {
      const response = ValidateConnectionStringResponse(
        6,
        isValid: false,
        errorMessage: 'missing DRIVER',
      );

      expect(response.isValid, isFalse);
      expect(response.errorMessage, 'missing DRIVER');
    });

    test('ConnectResponse carries connection id and optional error', () {
      const ok = ConnectResponse(7, 42);
      const fail = ConnectResponse(8, 0, error: 'Connect failed');

      expect(ok.connectionId, 42);
      expect(ok.error, isNull);
      expect(fail.connectionId, isZero);
      expect(fail.error, 'Connect failed');
    });
  });

  group('message protocol request defaults', () {
    test('ConnectRequest defaults timeoutMs to zero', () {
      const request = ConnectRequest(1, 'Driver={Test}');
      expect(request.timeoutMs, isZero);
      expect(request.type, RequestType.connect);
    });

    test('BeginTransactionRequest keeps legacy wire defaults', () {
      const request = BeginTransactionRequest(2, 9, 1);
      expect(request.savepointDialect, isZero);
      expect(request.accessMode, isZero);
      expect(request.lockTimeoutMs, isZero);
    });

    test('ExecuteQueryParamsRequest defaults resultEncoding to rowMajor', () {
      final request = ExecuteQueryParamsRequest(
        3,
        4,
        'SELECT 1',
        Uint8List(0),
      );
      expect(request.resultEncoding, ResultEncoding.rowMajor);
      expect(request.maxResultBufferBytes, isNull);
    });

    test('PoolCreateRequest and CatalogTablesRequest optional fields', () {
      const pool = PoolCreateRequest(5, 'Driver={Test}', 4, optionsJson: '{}');
      const tables = CatalogTablesRequest(6, 7);

      expect(pool.optionsJson, '{}');
      expect(tables.catalog, isEmpty);
      expect(tables.schema, isEmpty);
    });

    test('AuditGetEventsRequest defaults limit to zero', () {
      const request = AuditGetEventsRequest(8);
      expect(request.limit, isZero);
      expect(request.type, RequestType.auditGetEvents);
    });

    test('GetStructuredErrorForConnectionRequest is sendable', () async {
      final receivePort = ReceivePort();
      const request = GetStructuredErrorForConnectionRequest(9, 99);

      receivePort.sendPort.send(request);
      final message =
          await receivePort.first as GetStructuredErrorForConnectionRequest;
      receivePort.close();

      expect(message.connectionId, 99);
      expect(message.type, RequestType.getStructuredErrorForConnection);
    });
  });
}
