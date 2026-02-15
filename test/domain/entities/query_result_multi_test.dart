import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:test/test.dart';

void main() {
  group('QueryResultMulti', () {
    test('should expose firstResultSet, resultSets and rowCounts', () {
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
      expect(result.firstResultSet.columns, equals(['id']));
      expect(result.firstResultSet.rowCount, equals(1));
    });

    test('should return empty firstResultSet when no result set exists', () {
      const result = QueryResultMulti(
        items: [
          QueryResultMultiItem.rowCount(10),
        ],
      );

      expect(result.firstResultSet.columns, isEmpty);
      expect(result.firstResultSet.rows, isEmpty);
      expect(result.firstResultSet.rowCount, equals(0));
    });
  });
}
