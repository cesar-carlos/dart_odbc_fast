import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:test/test.dart';

const Endian _le = Endian.little;

/// Build a single result-set frame whose payload is a valid binary_protocol
/// v1 buffer with `columns` and `rows` (UTF-8 string columns, ASCII data).
Uint8List _buildResultSetFrame(List<String> columns, List<List<String>> rows) {
  // Reuse the same helper layout the integration test files use for
  // _createSingleResultSetBuffer: header(16) + cols + rows.
  final cols = <int>[];
  for (final c in columns) {
    final nameBytes = c.codeUnits;
    cols.addAll([
      0x01, 0x00, // odbcType = 1 (varchar)
      nameBytes.length & 0xFF, (nameBytes.length >> 8) & 0xFF, // name len
      ...nameBytes,
    ]);
  }
  final rowsBytes = <int>[];
  for (final row in rows) {
    for (final cell in row) {
      final cellBytes = cell.codeUnits;
      rowsBytes
        ..add(0) // not null
        ..addAll([
          cellBytes.length & 0xFF,
          (cellBytes.length >> 8) & 0xFF,
          (cellBytes.length >> 16) & 0xFF,
          (cellBytes.length >> 24) & 0xFF,
        ])
        ..addAll(cellBytes);
    }
  }
  final payloadAfterHeader = <int>[...cols, ...rowsBytes];

  final magic = [0x43, 0x42, 0x44, 0x4F]; // "ODBC" stored already-LE in tests
  // Magic is actually written as 0x4F444243 LE = bytes 43 42 44 4F.
  final colCount = columns.length;
  final rowCount = rows.length;
  final payloadSize = payloadAfterHeader.length;
  final header = <int>[
    ...magic,
    0x01, 0x00, // version = 1
    colCount & 0xFF, (colCount >> 8) & 0xFF,
    rowCount & 0xFF,
    (rowCount >> 8) & 0xFF,
    (rowCount >> 16) & 0xFF,
    (rowCount >> 24) & 0xFF,
    payloadSize & 0xFF,
    (payloadSize >> 8) & 0xFF,
    (payloadSize >> 16) & 0xFF,
    (payloadSize >> 24) & 0xFF,
  ];
  final inner = Uint8List.fromList([...header, ...payloadAfterHeader]);

  // Wrap in stream frame: tag(1) + len(4) + payload
  final out = BytesBuilder()
    ..addByte(multiStreamItemTagResultSet)
    ..add((ByteData(4)..setUint32(0, inner.length, _le)).buffer.asUint8List())
    ..add(inner);
  return out.toBytes();
}

Uint8List _buildRowCountFrame(int n) {
  final payload = ByteData(8)..setInt64(0, n, _le);
  final out = BytesBuilder()
    ..addByte(multiStreamItemTagRowCount)
    ..add((ByteData(4)..setUint32(0, 8, _le)).buffer.asUint8List())
    ..add(payload.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  group('MultiResultStreamDecoder', () {
    test('decodes a single row-count frame fed in one shot', () {
      final decoder = MultiResultStreamDecoder();
      final items = decoder.feed(_buildRowCountFrame(42));
      expect(items, hasLength(1));
      expect(items.single, isA<MultiResultItemRowCount>());
      expect((items.single as MultiResultItemRowCount).value, equals(42));
      expect(decoder.itemsDecoded, equals(1));
      expect(decoder.pendingBytes, equals(0));
      decoder.assertExhausted();
    });

    test('decodes a single result-set frame fed in one shot', () {
      final decoder = MultiResultStreamDecoder();
      final frame = _buildResultSetFrame(
        ['id', 'name'],
        [
          ['1', 'Alice'],
        ],
      );
      final items = decoder.feed(frame);
      expect(items, hasLength(1));
      expect(items.single, isA<MultiResultItemResultSet>());
      final rs = (items.single as MultiResultItemResultSet).value;
      expect(rs.columnNames, equals(['id', 'name']));
      expect(rs.rowCount, equals(1));
      decoder.assertExhausted();
    });

    test('coalesces multiple frames in a single chunk', () {
      final decoder = MultiResultStreamDecoder();
      final combined = BytesBuilder()
        ..add(_buildRowCountFrame(7))
        ..add(_buildRowCountFrame(13))
        ..add(
          _buildResultSetFrame(
            ['a'],
            [
              ['x'],
            ],
          ),
        );
      final items = decoder.feed(combined.toBytes());
      expect(items, hasLength(3));
      expect((items[0] as MultiResultItemRowCount).value, equals(7));
      expect((items[1] as MultiResultItemRowCount).value, equals(13));
      expect(items[2], isA<MultiResultItemResultSet>());
      decoder.assertExhausted();
    });

    test('handles a frame split across multiple feed() calls', () {
      final decoder = MultiResultStreamDecoder();
      final frame = _buildRowCountFrame(99);
      final mid = frame.length ~/ 2;
      final part1 = Uint8List.sublistView(frame, 0, mid);
      final part2 = Uint8List.sublistView(frame, mid);

      final firstBatch = decoder.feed(part1);
      expect(firstBatch, isEmpty);
      expect(decoder.pendingBytes, equals(part1.length));

      final secondBatch = decoder.feed(part2);
      expect(secondBatch, hasLength(1));
      expect((secondBatch.single as MultiResultItemRowCount).value, equals(99));
      decoder.assertExhausted();
    });

    test('rejects unknown frame tag', () {
      final decoder = MultiResultStreamDecoder();
      // tag = 99 (unknown), len = 0
      final bytes = Uint8List.fromList([99, 0, 0, 0, 0]);
      expect(() => decoder.feed(bytes), throwsFormatException);
    });

    test('rejects malformed row-count payload length', () {
      final decoder = MultiResultStreamDecoder();
      final bytes = BytesBuilder()
        ..addByte(multiStreamItemTagRowCount)
        ..add((ByteData(4)..setUint32(0, 4, _le)).buffer.asUint8List())
        ..add([1, 2, 3, 4]);
      expect(() => decoder.feed(bytes.toBytes()), throwsFormatException);
    });

    test('assertExhausted throws when bytes are buffered', () {
      final decoder = MultiResultStreamDecoder()
        ..feed(Uint8List.fromList([multiStreamItemTagRowCount, 1, 0, 0, 0]));
      expect(decoder.assertExhausted, throwsFormatException);
    });

    test('empty feed is a no-op', () {
      final decoder = MultiResultStreamDecoder();
      final items = decoder.feed(Uint8List(0));
      expect(items, isEmpty);
      decoder.assertExhausted();
    });
  });
}
