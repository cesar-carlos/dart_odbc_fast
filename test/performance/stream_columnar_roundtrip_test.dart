import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:test/test.dart';

void main() {
  group('decodeProtocolText lazyStrings', () {
    test('should_use_sublistView_without_copying_frame_bytes', () {
      final frame = Uint8List.fromList([0, 1, 2, 3, 4, ...'hi'.codeUnits]);
      final slice = Uint8List.sublistView(frame, 5);

      setBinaryProtocolLazyStrings(active: true);
      try {
        final cell = decodeProtocolText(slice);
        expect(cell, isA<LazyString>());
        final lazy = cell as LazyString;
        expect(identical(lazy.bytes, slice), isTrue);
        expect(lazy.value, 'hi');
      } finally {
        setBinaryProtocolLazyStrings(active: false);
      }
    });
  });

  group('parseColumnarToTyped lazyStrings', () {
    test('should_keep_LazyString_cells_without_eager_decode', () {
      final frame = _columnarNameFrame('perf');
      final typed = BinaryProtocolParser.parseColumnarToTyped(
        frame,
        lazyStrings: true,
      );
      final cell =
          typed.column<TypedColumnObject<Object>>('name').values.single!;
      expect(cell, isA<LazyString>());
      final lazy = cell as LazyString;
      expect(lazy.isDecoded, isFalse);
      expect(lazy.value, 'perf');
    });
  });

  group('fromTypedColumnar', () {
    test('should_round_trip_row_major_shape', () {
      const qr = QueryResult(
        columns: ['a'],
        rows: [
          [1],
          [2],
        ],
        rowCount: 2,
      );
      final typed = toTypedColumnar(qr);
      final back = fromTypedColumnar(typed);
      expect(back.columns, qr.columns);
      expect(back.rows, qr.rows);
      expect(back.rowCount, qr.rowCount);
    });
  });
}

Uint8List _columnarNameFrame(String name) {
  final nameBytes = name.codeUnits;
  final raw = <int>[
    0,
    ...nameBytes.length.toBytes(4),
    ...nameBytes,
  ];
  final payload = <int>[
    ...1.toBytes(2),
    ...'name'.length.toBytes(2),
    ...'name'.codeUnits,
    0,
    ...raw.length.toBytes(4),
    ...raw,
  ];
  return Uint8List.fromList([
    ...BinaryProtocolParser.magic.toBytes(4),
    ...BinaryProtocolParser.protocolVersionColumnarV2.toBytes(2),
    ...0.toBytes(2),
    ...1.toBytes(2),
    ...1.toBytes(4),
    0,
    ...payload.length.toBytes(4),
    ...payload,
  ]);
}

extension on int {
  List<int> toBytes(int length) {
    final bytes = <int>[];
    for (var i = 0; i < length; i++) {
      bytes.add((this >> (i * 8)) & 0xFF);
    }
    return bytes;
  }
}
