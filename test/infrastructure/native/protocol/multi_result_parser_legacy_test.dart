/// Unit tests for [MultiResultParser.getFirstResultSet].
library;

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:test/test.dart';

void main() {
  group('MultiResultParser.getFirstResultSet', () {
    test('should_return_null_when_items_list_is_empty', () {
      expect(MultiResultParser.getFirstResultSet(const []), isNull);
    });

    test('should_return_null_when_items_contain_only_row_counts', () {
      final items = <MultiResultItem>[
        const MultiResultItemRowCount(3),
        const MultiResultItemRowCount(0),
      ];
      expect(MultiResultParser.getFirstResultSet(items), isNull);
    });

    test('should_return_first_result_set_when_present', () {
      final first = ParsedRowBuffer(
        columns: const [],
        rows: const [],
        rowCount: 0,
        columnCount: 0,
      );
      final later = ParsedRowBuffer(
        columns: const [],
        rows: const [],
        rowCount: 0,
        columnCount: 0,
      );
      final items = <MultiResultItem>[
        const MultiResultItemRowCount(10),
        MultiResultItemResultSet(first),
        MultiResultItemResultSet(later),
      ];
      expect(MultiResultParser.getFirstResultSet(items), same(first));
    });
  });
}
