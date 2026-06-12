import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/helpers/query_result_access.dart';
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

  group('QueryResultAccess', () {
    const result = QueryResult(
      columns: ['ID', 'name'],
      rows: [
        [1, 'Alice'],
        [2, 'Bob'],
      ],
      rowCount: 2,
    );

    test('should_resolve_column_index_case_sensitively_by_default', () {
      expect(result.columnIndex('name'), equals(1));
      expect(result.columnIndex('ID'), equals(0));
      expect(result.columnIndex('missing'), isNull);
    });

    test('should_resolve_column_index_case_insensitively_when_requested', () {
      expect(result.columnIndex('id', ignoreCase: true), equals(0));
    });

    test('should_read_cells_and_row_maps', () {
      expect(result.cell(0, 'name'), equals('Alice'));
      expect(
        result.rowAsMap(1),
        equals(<String, Object?>{'ID': 2, 'name': 'Bob'}),
      );
    });

    test('should_extract_typed_column_values_and_first_value', () {
      expect(result.columnValues<int>('ID'), equals(<int?>[1, 2]));
      expect(result.firstValue<String>('name'), equals('Alice'));
    });

    test('should_expose_column_presence_and_typed_cell_access', () {
      expect(result.hasColumn('name'), isTrue);
      expect(result.hasColumn('missing'), isFalse);
      expect(result.hasColumn('id', ignoreCase: true), isTrue);
      expect(result.cellAs<int>(0, 'ID'), equals(1));
      expect(result.cellAs<String>(0, 'ID'), isNull);
    });

    test('should_materialize_rows_as_maps_and_first_row', () {
      expect(
        result.rowsAsMaps,
        equals(<Map<String, Object?>>[
          <String, Object?>{'ID': 1, 'name': 'Alice'},
          <String, Object?>{'ID': 2, 'name': 'Bob'},
        ]),
      );
      expect(
        result.firstRowOrNull,
        equals(<String, Object?>{'ID': 1, 'name': 'Alice'}),
      );
      expect(result.scalar<String>('name'), equals('Alice'));
    });

    test('should_return_null_first_row_when_empty', () {
      const empty = QueryResult(columns: ['id'], rows: [], rowCount: 0);
      expect(empty.firstRowOrNull, isNull);
      expect(empty.scalar<int>('id'), isNull);
      expect(empty.rowsAsMaps, isEmpty);
    });
  });
}
