import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:test/test.dart';

void main() {
  group('MultiResultParser', () {
    test('parse should decode a single result set', () {
      final buffer = _createSingleResultSetBuffer();
      final items = MultiResultParser.parse(buffer);

      expect(items.length, equals(1));
      expect(items[0].resultSet, isNotNull);
      expect(items[0].resultSet!.columnNames, equals(['id', 'name']));
      expect(
        items[0].resultSet!.rows,
        equals([
          [1, 'Alice'],
        ]),
      );
      expect(items[0].resultSet!.rowCount, equals(1));
      expect(items[0].rowCount, isNull);
    });

    test('parse should decode multiple result sets', () {
      final buffer = _createMultiResultSetBuffer();
      final items = MultiResultParser.parse(buffer);

      expect(items.length, equals(3));
      expect(items[0].resultSet, isNotNull);
      expect(items[0].resultSet!.columnNames, equals(['id', 'name']));
      expect(
        items[0].resultSet!.rows,
        equals([
          [1, 'Alice'],
        ]),
      );
      expect(items[0].rowCount, isNull);

      expect(items[1].rowCount, equals(42));

      expect(items[2].resultSet, isNotNull);
      expect(items[2].resultSet!.columnNames, equals(['id', 'email']));
      expect(
        items[2].resultSet!.rows,
        equals([
          [2, 'bob@example.com'],
        ]),
      );
      expect(items[2].rowCount, isNull);
    });

    test('parse should decode row count only', () {
      final buffer = _createRowCountOnlyBuffer();
      final items = MultiResultParser.parse(buffer);

      expect(items.length, equals(1));
      expect(items[0].resultSet, isNull);
      expect(items[0].rowCount, equals(42));
    });

    test('parse should handle empty multi-result', () {
      final buffer = _createEmptyMultiResultBuffer();
      final items = MultiResultParser.parse(buffer);

      expect(items.length, equals(0));
    });

    test('parse should throw on invalid buffer - too small for header', () {
      final buffer = Uint8List.fromList([0x01, 0x00]);

      expect(
        () => MultiResultParser.parse(buffer),
        throwsA(isA<FormatException>()),
      );
    });

    test('parse should throw on invalid buffer - truncated at item header', () {
      final buffer = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01, 0x00]);

      expect(
        () => MultiResultParser.parse(buffer),
        throwsA(isA<FormatException>()),
      );
    });

    test('parse should throw on invalid buffer - truncated at item payload',
        () {
      final buffer =
          Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]);

      expect(
        () => MultiResultParser.parse(buffer),
        throwsA(isA<FormatException>()),
      );
    });

    test('parse should throw on unknown tag', () {
      final buffer = Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x02]);

      expect(
        () => MultiResultParser.parse(buffer),
        throwsA(isA<FormatException>()),
      );
    });

    test('parse should throw on invalid row count payload length', () {
      final buffer =
          Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07]);

      expect(
        () => MultiResultParser.parse(buffer),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('getFirstResultSet', () {
    test('should return first result set when available', () {
      final buffer = _createSingleResultSetBuffer();
      final items = MultiResultParser.parse(buffer);
      final result = MultiResultParser.getFirstResultSet(items);

      expect(result, isNotNull);
      expect(result.columnNames, equals(['id', 'name']));
      expect(
        result.rows,
        equals([
          [1, 'Alice'],
        ]),
      );
      expect(result.rowCount, equals(1));
    });

    test('should return empty result set when no result sets', () {
      final buffer = _createEmptyMultiResultBuffer();
      final items = MultiResultParser.parse(buffer);
      final result = MultiResultParser.getFirstResultSet(items);

      expect(result, isNotNull);
      expect(result.columnNames, equals([]));
      expect(result.rows, equals([]));
      expect(result.rowCount, equals(0));
    });

    test('should return empty result set when only row counts', () {
      final buffer = _createRowCountOnlyBuffer();
      final items = MultiResultParser.parse(buffer);
      final result = MultiResultParser.getFirstResultSet(items);

      expect(result, isNotNull);
      expect(result.columnNames, equals([]));
      expect(result.rows, equals([]));
      expect(result.rowCount, equals(0));
    });
  });

  group('Integration Tests', () {
    test('should handle real multi-result query', () {
      final buffer = _createMultiResultSetBuffer();
      final items = MultiResultParser.parse(buffer);

      expect(items.length, equals(3));
      expect(items[0].resultSet, isNotNull);
      expect(items[1].rowCount, equals(42));
      expect(items[2].resultSet, isNotNull);

      final firstResultSet = MultiResultParser.getFirstResultSet(items);
      expect(firstResultSet.columnNames, equals(['id', 'name']));
      expect(
        firstResultSet.rows,
        equals([
          [1, 'Alice'],
        ]),
      );
    });

    test('should return empty result set when no result sets exist', () {
      final buffer = _createEmptyMultiResultBuffer();
      final items = MultiResultParser.parse(buffer);

      final firstResultSet = MultiResultParser.getFirstResultSet(items);
      expect(firstResultSet, isNotNull);
      expect(firstResultSet.columnNames, equals([]));
      expect(firstResultSet.rows, equals([]));
      expect(firstResultSet.rowCount, equals(0));
    });
  });
}

/// Creates result set buffer in Rust RowBufferEncoder format:
/// magic(4) + version(2) + col_count(2) + row_count(4) + payload_size(4)
/// + column metadata (odbc_type, name_len, name per col)
/// + row data (is_null, data_len, data per cell)
Uint8List _createSingleResultSetBuffer() {
  const magic = 0x4F444243;
  const version = 1;
  const colCount = 2;
  const rowCount = 1;
  const odbcInteger = 2;
  const odbcVarchar = 1;

  const metadataSize = (2 + 2 + 2) + (2 + 2 + 4);
  const rowDataSize = (1 + 4 + 4) + (1 + 4 + 5);
  const payloadSize = metadataSize + rowDataSize;

  final resultSetWriter = _BinaryBufferWriter()
    ..writeUint32(magic)
    ..writeUint16(version)
    ..writeUint16(colCount)
    ..writeUint32(rowCount)
    ..writeUint32(payloadSize)
    ..writeUint16(odbcInteger)
    ..writeUint16(2)
    ..addAll(Uint8List.fromList('id'.codeUnits))
    ..writeUint16(odbcVarchar)
    ..writeUint16(4)
    ..addAll(Uint8List.fromList('name'.codeUnits))
    ..writeUint8(0)
    ..writeUint32(4)
    ..writeUint32(1)
    ..writeUint8(0)
    ..writeUint32(5)
    ..addAll(Uint8List.fromList('Alice'.codeUnits));

  final resultSetData = resultSetWriter.toBytes();
  final writer = _BinaryBufferWriter()
    ..writeUint32(1)
    ..writeUint8(0x00)
    ..writeUint32(resultSetData.length)
    ..addAll(resultSetData);

  return writer.toBytes();
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

/// Creates a single result set buffer in Rust RowBufferEncoder format.
/// cols: list of (odbcType, nameLen, name)
/// rows: list of rows, each row is list of [dataLen, data] per cell
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

/// Creates 8-byte int64 LE payload for row count
/// (parser expects exactly 8 bytes)
Uint8List _createRowCountPayload(int value) {
  final w = _BinaryBufferWriter();
  for (var i = 0; i < 8; i++) {
    w.writeUint8((value >> (i * 8)) & 0xFF);
  }
  return w.toBytes();
}

Uint8List _createRowCountOnlyBuffer() {
  final rowCountData = _createRowCountPayload(42);
  final writer = _BinaryBufferWriter()
    ..writeUint32(1)
    ..writeUint8(0x01)
    ..writeUint32(8)
    ..addAll(rowCountData);

  return writer.toBytes();
}

Uint8List _createEmptyMultiResultBuffer() {
  final writer = _BinaryBufferWriter()..writeUint32(0x00000000);
  return writer.toBytes();
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
