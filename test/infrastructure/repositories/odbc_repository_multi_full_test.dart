import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

void _fakeWorkerMultiSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  final multiBuffer = _createMultiResultSetBuffer();

  receivePort.listen((Object? message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is ConnectRequest) {
      mainSendPort.send(ConnectResponse(message.requestId, 1));
      return;
    }
    if (message is ExecuteQueryMultiRequest) {
      mainSendPort.send(
        QueryResponse(message.requestId, data: multiBuffer),
      );
      return;
    }
    if (message is GetErrorRequest) {
      mainSendPort.send(GetErrorResponse(message.requestId, ''));
      return;
    }
    if (message is GetStructuredErrorRequest) {
      mainSendPort.send(const StructuredErrorResponse(0));
      return;
    }
    if (message is DisconnectRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

void main() {
  group('OdbcRepositoryImpl multi-result full mapping', () {
    late AsyncNativeOdbcConnection asyncNative;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      asyncNative =
          AsyncNativeOdbcConnection(isolateEntry: _fakeWorkerMultiSupport);
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
      final conn = await repository.connect('DSN=Fake');
      connectionId = conn.getOrNull()!.id;
    });

    tearDown(() {
      asyncNative.dispose();
    });

    test('executeQueryMultiFull should return full ordered items', () async {
      final result = await repository.executeQueryMultiFull(
        connectionId,
        'SELECT 1; UPDATE x SET y = 1',
      );

      expect(result.isSuccess(), isTrue);
      final multi = result.getOrNull()!;
      expect(multi.items.length, equals(3));
      expect(multi.resultSets.length, equals(2));
      expect(multi.rowCounts, equals([42]));

      final firstSet = multi.resultSets.first;
      const expectedRows = [
        [1, 'Alice'],
      ];
      expect(firstSet.columns, equals(['id', 'name']));
      expect(firstSet.rows, equals(expectedRows));
    });

    test('executeQueryMulti should keep compatibility and return first set',
        () async {
      final result = await repository.executeQueryMulti(
        connectionId,
        'SELECT 1; UPDATE x SET y = 1',
      );

      expect(result.isSuccess(), isTrue);
      final first = result.getOrNull()!;
      const expectedRows = [
        [1, 'Alice'],
      ];
      expect(first.columns, equals(['id', 'name']));
      expect(first.rows, equals(expectedRows));
      expect(first.rowCount, equals(1));
    });
  });
}

Uint8List _createMultiResultSetBuffer() {
  final resultSetData1 = _createResultSetPayload(
    [
      (2, 2, 'id'),
      (1, 4, 'name'),
    ],
    [
      [
        [
          4,
          Uint8List.fromList([1, 0, 0, 0]),
        ],
        [5, Uint8List.fromList('Alice'.codeUnits)],
      ],
    ],
  );

  final rowCountData = _createRowCountPayload(42);

  final resultSetData2 = _createResultSetPayload(
    [
      (2, 2, 'id'),
      (1, 5, 'email'),
    ],
    [
      [
        [
          4,
          Uint8List.fromList([2, 0, 0, 0]),
        ],
        [15, Uint8List.fromList('bob@example.com'.codeUnits)],
      ],
    ],
  );

  final writer = _BinaryBufferWriter()
    ..writeUint32(3)
    ..writeUint8(0x00)
    ..writeUint32(resultSetData1.length)
    ..addAll(resultSetData1)
    ..writeUint8(0x01)
    ..writeUint32(8)
    ..addAll(rowCountData)
    ..writeUint8(0x00)
    ..writeUint32(resultSetData2.length)
    ..addAll(resultSetData2);

  return writer.toBytes();
}

Uint8List _createResultSetPayload(
  List<(int, int, String)> cols,
  List<List<List<Object>>> rows,
) {
  const magic = 0x4F444243;
  const version = 1;

  var metadataSize = 0;
  for (final c in cols) {
    metadataSize += 2 + 2 + c.$3.length;
  }
  var rowDataSize = 0;
  for (final row in rows) {
    for (final pair in row) {
      rowDataSize += 1 + 4 + (pair[0] as int);
    }
  }
  final payloadSize = metadataSize + rowDataSize;

  final w = _BinaryBufferWriter()
    ..writeUint32(magic)
    ..writeUint16(version)
    ..writeUint16(cols.length)
    ..writeUint32(rows.length)
    ..writeUint32(payloadSize);

  for (final c in cols) {
    w
      ..writeUint16(c.$1)
      ..writeUint16(c.$2)
      ..addAll(Uint8List.fromList(c.$3.codeUnits));
  }
  for (final row in rows) {
    for (final pair in row) {
      final dataLen = pair[0] as int;
      final data = pair[1] as Uint8List;
      w
        ..writeUint8(0)
        ..writeUint32(dataLen)
        ..addAll(data);
    }
  }
  return w.toBytes();
}

Uint8List _createRowCountPayload(int value) {
  final w = _BinaryBufferWriter();
  for (var i = 0; i < 8; i++) {
    w.writeUint8((value >> (i * 8)) & 0xFF);
  }
  return w.toBytes();
}

class _BinaryBufferWriter {
  final List<int> _bytes = [];

  void writeUint8(int value) {
    _bytes.add(value & 0xFF);
  }

  void writeUint16(int value) {
    _bytes
      ..add(value & 0xFF)
      ..add((value >> 8) & 0xFF);
  }

  void writeUint32(int value) {
    _bytes
      ..add(value & 0xFF)
      ..add((value >> 8) & 0xFF)
      ..add((value >> 16) & 0xFF)
      ..add((value >> 24) & 0xFF);
  }

  void addAll(Uint8List data) {
    _bytes.addAll(data);
  }

  Uint8List toBytes() {
    return Uint8List.fromList(_bytes);
  }
}
