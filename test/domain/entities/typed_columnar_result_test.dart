/// Unit tests for [TypedColumnarResult] + [toTypedColumnar].
library;

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void main() {
  group('toTypedColumnar', () {
    test('should_pick_int32_when_all_values_fit_in_signed_32_bits', () {
      const qr = QueryResult(
        columns: ['id'],
        rows: [
          [1],
          [42],
          [-100],
        ],
        rowCount: 3,
      );

      final tc = toTypedColumnar(qr);
      expect(tc.rowCount, equals(3));
      expect(tc.columnCount, equals(1));

      final col = tc.column<TypedColumnInt32>('id');
      expect(col.values, orderedEquals([1, 42, -100]));
      expect(col.isNullAt(0), isFalse);
      expect(col.isNullAt(1), isFalse);
    });

    test('should_pick_int64_when_any_value_overflows_int32', () {
      const qr = QueryResult(
        columns: ['big'],
        rows: [
          [1],
          [10000000000], // > 2^31
        ],
        rowCount: 2,
      );

      final tc = toTypedColumnar(qr);
      final col = tc.column<TypedColumnInt64>('big');
      expect(col.values, orderedEquals([1, 10000000000]));
    });

    test('should_record_null_via_bitmap_for_int32_column', () {
      const qr = QueryResult(
        columns: ['id'],
        rows: [
          [1],
          [null],
          [3],
          [null],
          [5],
        ],
        rowCount: 5,
      );

      final col = toTypedColumnar(qr).column<TypedColumnInt32>('id');
      expect(col.isNullAt(0), isFalse);
      expect(col.isNullAt(1), isTrue);
      expect(col.isNullAt(2), isFalse);
      expect(col.isNullAt(3), isTrue);
      expect(col.isNullAt(4), isFalse);
      // Slot value for null rows is the default 0 — bitmap is authoritative.
      expect(col.values[1], equals(0));
    });

    test('should_pick_float64_for_double_columns', () {
      const qr = QueryResult(
        columns: ['v'],
        rows: [
          [1.5],
          [2.25],
          [-0.5],
        ],
        rowCount: 3,
      );

      final col = toTypedColumnar(qr).column<TypedColumnFloat64>('v');
      expect(col.values, orderedEquals([1.5, 2.25, -0.5]));
    });

    test('should_keep_strings_in_TypedColumnObject', () {
      const qr = QueryResult(
        columns: ['name'],
        rows: [
          ['alice'],
          [null],
          ['bob'],
        ],
        rowCount: 3,
      );

      final col = toTypedColumnar(qr).column<TypedColumnObject<String>>('name');
      expect(col.values, orderedEquals(['alice', null, 'bob']));
      expect(col.isNullAt(1), isTrue);
      expect(col.kind, equals(TypedColumnKind.string));
    });

    test('should_handle_mixed_columns_in_one_result', () {
      const qr = QueryResult(
        columns: ['id', 'name', 'score'],
        rows: [
          [1, 'alice', 9.5],
          [2, 'bob', 7.25],
          [3, null, null],
        ],
        rowCount: 3,
      );

      final tc = toTypedColumnar(qr);
      expect(tc.columnCount, equals(3));
      expect(tc.column<TypedColumnInt32>('id').values, hasLength(3));
      expect(tc.column<TypedColumnObject<String>>('name').values[2], isNull);
      expect(tc.column<TypedColumnFloat64>('score').isNullAt(2), isTrue);
    });

    test('should_throw_StateError_when_column_name_is_unknown', () {
      const qr = QueryResult(
        columns: ['id'],
        rows: [
          [1],
        ],
        rowCount: 1,
      );

      final tc = toTypedColumnar(qr);
      expect(
        () => tc.column<TypedColumnInt32>('missing'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });

    test('should_throw_StateError_when_requested_type_does_not_match', () {
      const qr = QueryResult(
        columns: ['v'],
        rows: [
          [1.5],
        ],
        rowCount: 1,
      );

      final tc = toTypedColumnar(qr);
      expect(
        () => tc.column<TypedColumnInt32>('v'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TypedColumnFloat64'),
          ),
        ),
      );
    });

    test('should_expose_length_and_isNullAt_on_every_concrete_column', () {
      const qr = QueryResult(
        columns: ['i32', 'i64', 'f64', 'name'],
        rows: [
          [1, 10000000000, 1.5, 'alice'],
          [null, null, null, null],
          [3, 20000000000, 3.5, 'carol'],
        ],
        rowCount: 3,
      );

      final tc = toTypedColumnar(qr);
      final int32Col = tc.column<TypedColumnInt32>('i32');
      final int64Col = tc.column<TypedColumnInt64>('i64');
      final float64Col = tc.column<TypedColumnFloat64>('f64');
      final stringCol = tc.column<TypedColumnObject<String>>('name');

      expect(int32Col.length, equals(3));
      expect(int64Col.length, equals(3));
      expect(float64Col.length, equals(3));
      expect(stringCol.length, equals(3));

      expect(int32Col.isNullAt(1), isTrue);
      expect(int32Col.isNullAt(0), isFalse);
      expect(int64Col.isNullAt(1), isTrue);
      expect(int64Col.isNullAt(0), isFalse);
      expect(float64Col.isNullAt(1), isTrue);
      expect(float64Col.isNullAt(0), isFalse);
      expect(stringCol.isNullAt(1), isTrue);
      expect(stringCol.isNullAt(0), isFalse);
    });

    test('should_classify_column_with_only_nulls_as_unknown', () {
      const qr = QueryResult(
        columns: ['unknown'],
        rows: [
          [null],
          [null],
        ],
        rowCount: 2,
      );

      final col =
          toTypedColumnar(qr).column<TypedColumnObject<Object>>('unknown');
      expect(col.kind, equals(TypedColumnKind.unknown));
      expect(col.values, orderedEquals(<Object?>[null, null]));
    });
  });
}
