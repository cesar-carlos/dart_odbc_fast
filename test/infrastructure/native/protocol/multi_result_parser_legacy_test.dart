/// Unit tests for the deprecated legacy [MultiResultItem] factory and
/// the [MultiResultParser.getFirstResultSet] convenience helper.
///
/// The sealed `MultiResultItem` surface offers `MultiResultItemResultSet`
/// and `MultiResultItemRowCount` as the canonical variants; the legacy
/// factory `MultiResultItem(...)` is preserved for backwards compatibility
/// with pre-v3.0 callers. These tests pin its accessor behaviour so the
/// transition to v4.0 is intentional.
library;

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:test/test.dart';

void main() {
  group('Deprecated MultiResultItem factory accessors', () {
    final emptyBuffer = ParsedRowBuffer(
      columns: const [],
      rows: const [],
      rowCount: 0,
      columnCount: 0,
    );

    test(
      'legacy resultSet variant should_expose_resultSet_via_accessor',
      () {
        // Intentionally exercise the deprecated factory to pin its
        // accessor behaviour until v4.0 removes it.
        // ignore: deprecated_member_use_from_same_package
        final item = MultiResultItem(
          resultSet: emptyBuffer,
          rowCount: null,
        );
        expect(item.resultSet, same(emptyBuffer));
        expect(item.rowCount, isNull);
      },
    );

    test('legacy rowCount variant should_expose_rowCount_via_accessor', () {
      // Intentionally exercise the deprecated factory to pin its
      // accessor behaviour until v4.0 removes it.
      // ignore: deprecated_member_use_from_same_package
      const item = MultiResultItem(resultSet: null, rowCount: 7);
      expect(item.resultSet, isNull);
      expect(item.rowCount, equals(7));
    });

    test(
      'legacy item with both fields null should_return_null_from_accessors',
      () {
        // Defensive contract: even malformed legacy payloads must not
        // throw on accessor read.
        // ignore: deprecated_member_use_from_same_package
        const item = MultiResultItem(resultSet: null, rowCount: null);
        expect(item.resultSet, isNull);
        expect(item.rowCount, isNull);
      },
    );
  });

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
