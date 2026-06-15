/// Unit tests for [OdbcResultParser].
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart';
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
  });
}
