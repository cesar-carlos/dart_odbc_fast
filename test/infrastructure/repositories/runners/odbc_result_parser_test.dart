/// Unit tests for [OdbcResultParser].
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:test/test.dart';

Uint8List _singleRowBuffer() {
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

/// Minimal columnar v2 frame: one INTEGER column `n` with value 42.
Uint8List _columnarV2SingleInt() {
  final b = <int>[];
  void u16(int v) => b.addAll(_le16(v));
  void u32(int v) => b.addAll(_le32(v));

  u32(BinaryProtocolParser.magic);
  u16(BinaryProtocolParser.protocolVersionColumnarV2);
  u16(0);
  u16(1);
  u32(1);
  b.add(0);
  u32(0);
  final payloadAt = b.length;
  u16(2);
  u16(1);
  b
    ..add('n'.codeUnitAt(0))
    ..add(0);
  u32(5);
  b
    ..add(0)
    ..addAll(_le32(42));
  final pay = b.length - payloadAt;
  b[15] = pay & 0xff;
  b[16] = (pay >> 8) & 0xff;
  b[17] = (pay >> 16) & 0xff;
  b[18] = (pay >> 24) & 0xff;
  return Uint8List.fromList(b);
}

Uint8List _multV2WithFirstResultSet(Uint8List inner) {
  final out = BytesBuilder()
    ..add(_le32(multiResultMagic))
    ..add(_le16(multiResultVersionV2))
    ..add(_le16(0))
    ..add(_le32(1))
    ..addByte(MultiResultParser.tagResultSet)
    ..add(_le32(inner.length))
    ..add(inner);
  return out.toBytes();
}

List<int> _le32(int v) => List.generate(4, (i) => (v >> (i * 8)) & 0xFF);

List<int> _le16(int v) => [(v & 0xFF), (v >> 8) & 0xFF];

void main() {
  const parser = OdbcResultParser();

  group('OdbcResultParser', () {
    test('should_return_null_for_null_buffer', () {
      expect(parser.parseBufferToQueryResult(null), isNull);
    });

    test('should_return_empty_result_for_zero_length_buffer', () {
      final result = parser.parseBufferToQueryResult(Uint8List(0));
      expect(
        result,
        equals(const QueryResult(columns: [], rows: [], rowCount: 0)),
      );
    });

    test('should_parse_single_row_major_buffer', () {
      final result = parser.parseBufferToQueryResult(_singleRowBuffer());
      expect(result, isNotNull);
      expect(result!.columns, equals(['id']));
      expect(result.rowCount, equals(1));
      expect(result.rows.single.single, equals(42));
    });

    test('should_return_null_for_malformed_buffer', () {
      final result = parser.parseBufferToQueryResult(
        Uint8List.fromList([1, 2, 3]),
      );
      expect(result, isNull);
    });

    test('toQueryResultMulti maps result sets and row counts', () {
      final multi = parser.toQueryResultMulti([
        MultiResultItemResultSet(
          ParsedRowBuffer(
            columns: const [],
            rows: const [
              [1],
            ],
            rowCount: 1,
            columnCount: 1,
          ),
        ),
        const MultiResultItemRowCount(3),
      ]);
      expect(multi.items, hasLength(2));
      expect(multi.items[1].rowCount, equals(3));
    });

    test(
      'should_decode_mult_first_columnar_result_set_directly_to_typed',
      () {
        final inner = _columnarV2SingleInt();
        expect(BinaryProtocolParser.isColumnarV2Message(inner), isTrue);

        final mult = _multV2WithFirstResultSet(inner);
        final peeked = MultiResultParser.peekFirstResultSetPayload(mult);
        expect(peeked, isNotNull);
        expect(BinaryProtocolParser.isColumnarV2Message(peeked!), isTrue);

        final typed = parser.parseBufferToTypedColumnar(mult);
        expect(typed, isNotNull);
        expect(typed!.rowCount, 1);
        expect(typed.columns, hasLength(1));
        final col = typed.columns.single;
        expect(col, isA<TypedColumnInt32>());
        expect((col as TypedColumnInt32).values[0], 42);
      },
    );

    test(
      'should_fall_back_to_row_materialize_when_mult_first_rs_is_row_major',
      () {
        final mult = _multV2WithFirstResultSet(_singleRowBuffer());
        final typed = parser.parseBufferToTypedColumnar(mult);
        expect(typed, isNotNull);
        expect(typed!.rowCount, 1);
        expect(typed.columns.single, isA<TypedColumnInt32>());
        expect((typed.columns.single as TypedColumnInt32).values[0], 42);
      },
    );

    test(
      'should_decode_row_major_buffer_to_typed_via_wire_discriminants',
      () {
        final typed = parser.parseBufferToTypedColumnar(_singleRowBuffer());
        expect(typed, isNotNull);
        expect(typed!.rowCount, 1);
        expect(typed.columns.single, isA<TypedColumnInt32>());
        expect((typed.columns.single as TypedColumnInt32).values[0], 42);
      },
    );
  });
}
