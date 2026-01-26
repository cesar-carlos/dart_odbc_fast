import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BinaryProtocolParser', () {
    test('should validate magic number', () {
      final invalidBuffer = Uint8List(16);
      expect(
        () => BinaryProtocolParser.parse(invalidBuffer),
        throwsFormatException,
      );
    });

    test('should parse simple buffer with one column and one row', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'id', type: 2),
        ],
        rows: [
          [1],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.columnCount, equals(1));
      expect(result.rowCount, equals(1));
      expect(result.columns[0].name, equals('id'));
      expect(result.columns[0].odbcType, equals(2));
      expect(result.rows[0][0], equals(1));
    });

    test('should handle null values', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'value', type: 1),
        ],
        rows: [
          [null],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.rows[0][0], isNull);
    });

    test('should parse multiple columns and rows', () {
      final buffer = _createTestBuffer(
        columns: [
          (name: 'id', type: 2),
          (name: 'name', type: 1),
        ],
        rows: [
          [1, 'Alice'],
          [2, 'Bob'],
        ],
      );

      final result = BinaryProtocolParser.parse(buffer);

      expect(result.columnCount, equals(2));
      expect(result.rowCount, equals(2));
      expect(result.rows[0][0], equals(1));
      expect(result.rows[0][1], equals('Alice'));
      expect(result.rows[1][0], equals(2));
      expect(result.rows[1][1], equals('Bob'));
    });
  });
}

Uint8List _createTestBuffer({
  required List<({String name, int type})> columns,
  required List<List<dynamic>> rows,
}) {
  final buffer = <int>[];

  const magic = 0x4F444243;
  const version = 1;

  buffer
    ..addAll(magic.toBytes(4))
    ..addAll(version.toBytes(2))
    ..addAll(columns.length.toBytes(2))
    ..addAll(rows.length.toBytes(4));

  var payloadSize = 0;
  for (final col in columns) {
    payloadSize += 2 + 2 + col.name.length;
  }
  for (final row in rows) {
    for (final cell in row) {
      payloadSize += 1;
      if (cell != null) {
        final data = _cellToBytes(cell);
        payloadSize += 4 + data.length;
      }
    }
  }

  buffer.addAll(payloadSize.toBytes(4));

  for (final col in columns) {
    buffer
      ..addAll(col.type.toBytes(2))
      ..addAll(col.name.length.toBytes(2))
      ..addAll(col.name.codeUnits);
  }

  for (final row in rows) {
    for (final cell in row) {
      if (cell == null) {
        buffer.add(1);
      } else {
        buffer.add(0);
        final data = _cellToBytes(cell);
        buffer
          ..addAll(data.length.toBytes(4))
          ..addAll(data);
      }
    }
  }

  return Uint8List.fromList(buffer);
}

List<int> _cellToBytes(dynamic cell) {
  if (cell is int) {
    return cell.toBytes(4);
  } else if (cell is String) {
    return cell.codeUnits;
  }
  return [];
}

extension IntBytes on int {
  List<int> toBytes(int length) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      bytes.add((this >> (i * 8)) & 0xFF);
    }
    return bytes;
  }
}
