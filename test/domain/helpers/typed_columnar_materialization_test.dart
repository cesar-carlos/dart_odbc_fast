import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/typed_columnar_result.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:test/test.dart';

void main() {
  test('should_preserve_values_nulls_and_lazy_strings_when_materializing', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final date = DateTime.utc(2026);
    final largeInt = int.parse('9007199254740993');
    final lazy = LazyString(Uint8List.fromList([104, 105]));
    final result = TypedColumnarResult(
      rowCount: 3,
      columns: [
        TypedColumnInt32(
          name: 'i32',
          values: Int32List.fromList([-2147483648, 9, 2147483647]),
          nullBitmap: Uint8List.fromList([2]),
        ),
        TypedColumnInt64(
          name: 'i64',
          values: Int64List.fromList([-largeInt, 9, largeInt]),
          nullBitmap: Uint8List.fromList([2]),
        ),
        TypedColumnFloat64(
          name: 'f64',
          values: Float64List.fromList([-0.0, 9, double.infinity]),
          nullBitmap: Uint8List.fromList([2]),
        ),
        TypedColumnObject<Object>(
          name: 'text',
          kind: TypedColumnKind.string,
          values: [lazy, null, 'last'],
        ),
        TypedColumnObject<Uint8List>(
          name: 'bytes',
          kind: TypedColumnKind.bytes,
          values: [bytes, null, bytes],
        ),
        TypedColumnObject<DateTime>(
          name: 'date',
          kind: TypedColumnKind.dateTime,
          values: [date, null, date],
        ),
        TypedColumnObject<bool>(
          name: 'bool',
          kind: TypedColumnKind.bool_,
          values: [true, null, false],
        ),
        TypedColumnObject<String>(
          name: 'decimal',
          kind: TypedColumnKind.decimal,
          values: ['1.25', null, '-2.50'],
        ),
      ],
    );
    final converted = fromTypedColumnar(result);
    expect(
      converted.columns,
      ['i32', 'i64', 'f64', 'text', 'bytes', 'date', 'bool', 'decimal'],
    );
    expect(converted.rows[0], [
      -2147483648,
      -largeInt,
      -0.0,
      lazy,
      bytes,
      date,
      true,
      '1.25',
    ]);
    expect(identical(converted.rows[0][3], lazy), isTrue);
    expect(converted.rows[1], List<Object?>.filled(8, null));
    expect(converted.rows[2], [
      2147483647,
      largeInt,
      double.infinity,
      'last',
      bytes,
      date,
      false,
      '-2.50',
    ]);
    expect((converted.rows[0][2] as double).isNegative, isTrue);
    expect(identical(converted.rows[0][4], bytes), isTrue);
    converted.rows[0][0] = 5;
    expect((result.columns[0] as TypedColumnInt32).values[0], -2147483648);
  });

  test('should_preserve_empty_shapes_when_materializing', () {
    final noRows = fromTypedColumnar(
      TypedColumnarResult(
        rowCount: 0,
        columns: [
          TypedColumnInt32(
            name: 'id',
            values: Int32List(0),
            nullBitmap: Uint8List(0),
          ),
        ],
      ),
    );
    expect(noRows.columns, ['id']);
    expect(noRows.rows, isEmpty);
    final noColumns =
        fromTypedColumnar(TypedColumnarResult(rowCount: 2, columns: []));
    expect(noColumns.rows, [<Object?>[], <Object?>[]]);
    expect(noColumns.rowCount, 2);
  });
}
