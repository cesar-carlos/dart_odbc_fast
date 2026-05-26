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

  group('QueryResult.columnsMetadata', () {
    test('defaults to null for legacy callers', () {
      const r = QueryResult(columns: ['id'], rows: [], rowCount: 0);
      expect(r.columnsMetadata, isNull);
    });

    test('accepts metadata when provided by parser', () {
      const meta = <ColumnMetadata>[
        ColumnMetadata(name: 'id', odbcType: 2),
      ];
      const r = QueryResult(
        columns: ['id'],
        rows: [],
        rowCount: 0,
        columnsMetadata: meta,
      );
      expect(r.columnsMetadata, hasLength(1));
      expect(r.columnsMetadata!.first.name, equals('id'));
      expect(r.columnsMetadata!.first.odbcType, equals(2));
    });

    test('matches columns length when populated', () {
      const meta = <ColumnMetadata>[
        ColumnMetadata(name: 'a', odbcType: 1),
        ColumnMetadata(name: 'b', odbcType: 2),
      ];
      const r = QueryResult(
        columns: ['a', 'b'],
        rows: [],
        rowCount: 0,
        columnsMetadata: meta,
      );
      expect(r.columnsMetadata!.length, equals(r.columns.length));
    });
  });
}
