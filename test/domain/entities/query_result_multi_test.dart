import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:test/test.dart';

void main() {
  group('QueryResultMulti', () {
    test('should expose firstResultSetOrNull, resultSets and rowCounts', () {
      const result = QueryResultMulti(
        items: [
          QueryResultMultiItem.rowCount(5),
          QueryResultMultiItem.resultSet(
            QueryResult(
              columns: ['id'],
              rows: [
                [1],
              ],
              rowCount: 1,
            ),
          ),
          QueryResultMultiItem.rowCount(3),
        ],
      );

      expect(result.isNotEmpty, isTrue);
      expect(result.resultSets.length, equals(1));
      expect(result.rowCounts, equals([5, 3]));
      expect(result.firstResultSetOrNull, isNotNull);
      expect(result.firstResultSetOrNull!.columns, equals(['id']));
      expect(result.firstResultSetOrNull!.rowCount, equals(1));
    });

    test(
        'should return null firstResultSetOrNull when no result set '
        '(M7 fix v3.2.0)', () {
      const result = QueryResultMulti(
        items: [
          QueryResultMultiItem.rowCount(10),
        ],
      );

      expect(result.firstResultSetOrNull, isNull);
    });

    test('isEmpty should_be_true_for_empty_items_list', () {
      const result = QueryResultMulti(items: []);
      expect(result.isEmpty, isTrue);
      expect(result.isNotEmpty, isFalse);
    });
  });

  group('QueryResultMultiItem', () {
    test('isResultSet should_be_true_for_resultSet_variant', () {
      const item = QueryResultMultiItem.resultSet(
        QueryResult(columns: [], rows: [], rowCount: 0),
      );
      expect(item.isResultSet, isTrue);
      expect(item.isRowCount, isFalse);
    });

    test('isRowCount should_be_true_for_rowCount_variant', () {
      const item = QueryResultMultiItem.rowCount(7);
      expect(item.isResultSet, isFalse);
      expect(item.isRowCount, isTrue);
    });
  });
}
