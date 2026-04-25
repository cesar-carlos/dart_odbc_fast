import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:test/test.dart';

void main() {
  group('QueryResult', () {
    test('reports empty and optional payload flags', () {
      const result = QueryResult(
        columns: ['id'],
        rows: [],
        rowCount: 0,
      );

      expect(result.isEmpty, isTrue);
      expect(result.isNotEmpty, isFalse);
      expect(result.hasOutputParamValues, isFalse);
      expect(result.hasRefCursorResults, isFalse);
      expect(result.hasAdditionalResults, isFalse);
    });

    test('reports non-empty result and directed payload flags', () {
      const refCursor = QueryResult(
        columns: ['name'],
        rows: [
          ['alice'],
        ],
        rowCount: 1,
      );
      const result = QueryResult(
        columns: ['id'],
        rows: [
          [1],
        ],
        rowCount: 1,
        outputParamValues: ['ok'],
        refCursorResults: [refCursor],
        additionalResults: [
          DirectedRowCountItem(3),
          DirectedResultItem(
            columns: ['value'],
            rows: [
              [42],
            ],
            rowCount: 1,
          ),
        ],
      );

      expect(result.isEmpty, isFalse);
      expect(result.isNotEmpty, isTrue);
      expect(result.hasOutputParamValues, isTrue);
      expect(result.hasRefCursorResults, isTrue);
      expect(result.hasAdditionalResults, isTrue);
      expect(result.additionalResults.first, isA<DirectedRowCountItem>());
      expect(result.additionalResults.last, isA<DirectedResultItem>());
    });
  });
}
