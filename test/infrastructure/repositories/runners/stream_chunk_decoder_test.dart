/// Unit tests for [StreamChunkDecoder].
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_chunk_decoder.dart';
import 'package:test/test.dart';

Uint8List _rowMajorSingleIntBuffer() {
  const magic = BinaryProtocolParser.magic;
  const version = 1;
  const columnCount = 1;
  const rowCount = 1;
  const odbcInteger = 2;
  const columnName = 'id';
  const payloadSize = 15;

  final bytes = <int>[
    ..._le32(magic),
    ..._le16(version),
    ..._le16(columnCount),
    ..._le32(rowCount),
    ..._le32(payloadSize),
    ..._le16(odbcInteger),
    ..._le16(columnName.length),
    ...columnName.codeUnits,
    0,
    ..._le32(4),
    ..._le32(42),
  ];
  return Uint8List.fromList(bytes);
}

List<int> _le32(int v) => List.generate(4, (i) => (v >> (i * 8)) & 0xFF);

List<int> _le16(int v) => [(v & 0xFF), (v >> 8) & 0xFF];

void main() {
  const parser = OdbcResultParser();
  const decoder = StreamChunkDecoder(parser);

  group('StreamChunkDecoder', () {
    test('should_decode_columnar_v2_frame_directly', () {
      final frame = _createColumnarV2Buffer(
        columns: const [
          (name: 'id', type: 2),
        ],
        rows: [
          [7],
        ],
      );

      final typed = decoder.decodeColumnarFrame(frame);

      expect(typed.rowCount, 1);
      expect(typed.columnCount, 1);
      expect(typed.column<TypedColumnInt32>('id').values.single, 7);
    });

    test('should_decode_row_major_v1_frame_via_parser_fallback', () {
      final frame = _rowMajorSingleIntBuffer();
      final expected = toTypedColumnar(
        parser.parseBufferToQueryResult(frame)!,
      );

      final typed = decoder.decodeColumnarFrame(frame);

      expect(typed.rowCount, expected.rowCount);
      expect(
        typed.column<TypedColumnInt32>('id').values,
        orderedEquals(expected.column<TypedColumnInt32>('id').values),
      );
    });

    test('should_forward_lazyStrings_to_columnar_v2_decode', () {
      final frame = _createColumnarV2Buffer(
        columns: const [
          (name: 'name', type: 1),
        ],
        rows: [
          ['Alice'],
        ],
      );

      final typed = decoder.decodeColumnarFrame(frame, lazyStrings: true);

      expect(typed.rowCount, 1);
      final nameCell =
          typed.column<TypedColumnObject<Object>>('name').values.single!;
      expect(nameCell, isA<LazyString>());
      final lazy = nameCell as LazyString;
      expect(lazy.isDecoded, isFalse);
      expect(lazy.value, 'Alice');
    });

    test('should_return_null_from_decodeExecuteBuffer_when_buffer_null', () {
      expect(decoder.decodeExecuteBuffer(null), isNull);
    });

    test('should_return_empty_result_from_decodeExecuteBuffer_for_zero_length',
        () {
      final typed = decoder.decodeExecuteBuffer(Uint8List(0));
      expect(typed, isNotNull);
      expect(typed!.rowCount, 0);
      expect(typed.columnCount, 0);
    });

    test('should_decode_execute_buffer_to_typed_columnar', () {
      final buf = _rowMajorSingleIntBuffer();
      final typed = decoder.decodeExecuteBuffer(buf);

      expect(typed, isNotNull);
      expect(typed!.column<TypedColumnInt32>('id').values.single, 42);
    });
  });
}

Uint8List _createColumnarV2Buffer({
  required List<({String name, int type})> columns,
  required List<List<dynamic>> rows,
}) {
  final payload = <int>[];
  for (var c = 0; c < columns.length; c++) {
    final column = columns[c];
    payload
      ..addAll(column.type.toBytes(2))
      ..addAll(column.name.length.toBytes(2))
      ..addAll(column.name.codeUnits)
      ..add(0);

    final raw = <int>[];
    for (final row in rows) {
      final cell = row[c];
      if (cell == null) {
        raw.add(1);
        continue;
      }
      raw.add(0);
      if (column.type == 2) {
        raw.addAll((cell as int).toBytes(4));
      } else {
        final bytes = _cellToBytes(cell);
        raw
          ..addAll(bytes.length.toBytes(4))
          ..addAll(bytes);
      }
    }
    payload
      ..addAll(raw.length.toBytes(4))
      ..addAll(raw);
  }

  final buffer = <int>[
    ...BinaryProtocolParser.magic.toBytes(4),
    ...BinaryProtocolParser.protocolVersionColumnarV2.toBytes(2),
    ...0.toBytes(2),
    ...columns.length.toBytes(2),
    ...rows.length.toBytes(4),
    0,
    ...payload.length.toBytes(4),
    ...payload,
  ];

  return Uint8List.fromList(buffer);
}

List<int> _cellToBytes(dynamic cell) {
  if (cell is int) {
    return cell.toBytes(4);
  } else if (cell is String) {
    return cell.codeUnits;
  } else if (cell is List<int>) {
    return cell;
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
