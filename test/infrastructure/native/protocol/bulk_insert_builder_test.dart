import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';
import 'package:test/test.dart';

/// Nullability validation tests for bulk insert behavior.
void main() {
  group('Phase 2: Non-nullable null validation', () {
    test('non-nullable i32 column throws in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow([null]),
        throwsA(
          isA<StateError>()
              .having(
                (e) => e.message,
                'message',
                contains('is non-nullable but contains null'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('Column "a"'),
              ),
        ),
      );
    });

    test('non-nullable text column throws in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.text, maxLen: 10)
            .addRow([null]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('at row 1'),
          ),
        ),
      );
    });

    test('non-nullable i64 column throws in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i64)
            .addRow([null]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is non-nullable but contains null'),
          ),
        ),
      );
    });

    test(
      'non-nullable decimal column throws in addRow',
      () {
        expect(
          () => BulkInsertBuilder()
              .table('t')
              .addColumn('a', BulkColumnType.decimal, maxLen: 20)
              .addRow([null]),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is non-nullable but contains null'),
            ),
          ),
        );
      },
    );

    test(
      'non-nullable timestamp column throws in addRow',
      () {
        expect(
          () => BulkInsertBuilder()
              .table('t')
              .addColumn('a', BulkColumnType.timestamp)
              .addRow([null]),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is non-nullable but contains null'),
            ),
          ),
        );
      },
    );

    test(
      'nullable column with null sets null bitmap correctly',
      () {
        final b = BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32, nullable: true)
            .addRow([null]).addRow([1]);
        final enc = b.build();

        // For nullable columns, there should be a null bitmap
        // Offset calculation: table(5) + col(15) + rowCount(4) = 24
        // Bitmap starts at offset 24
        expect(enc.length, greaterThan(24));
        // Bitmap byte: bit 0 should be set (first row is null)
        expect(enc[24] & 1, equals(1));
      },
    );

    test('error message shows correct row number', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow([1]).addRow([null]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('at row 2'),
          ),
        ),
      );
    });

    test('i32 column rejects string value in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow(['1']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects i32 value'),
          ),
        ),
      );
    });

    test('i32 column rejects out-of-range value in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow([0x80000000]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('i64 column rejects non-int value in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i64)
            .addRow([1.5]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects i64 value'),
          ),
        ),
      );
    });

    test('text column rejects non-string value in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.text, maxLen: 10)
            .addRow([123]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects text value'),
          ),
        ),
      );
    });

    test('text column rejects value longer than maxLen in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.text, maxLen: 3)
            .addRow(['abcd']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('exceeds max length 3'),
          ),
        ),
      );
    });

    test('text column rejects UTF-8 byte length overflow (emoji)', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.text, maxLen: 2)
            .addRow(['😀']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('UTF-8 encoding exceeds max length'),
          ),
        ),
      );
    });

    test('text column accepts combining characters when within limits', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.text, maxLen: 4)
          .addRow(['e\u0301']);
      expect(b.build, returnsNormally);
    });

    test('decimal column accepts string and num values', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.decimal, maxLen: 20)
          .addRow(['12.34']).addRow([56.78]);
      expect(b.build, returnsNormally);
    });

    test('decimal column rejects unsupported value type in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.decimal, maxLen: 20)
            .addRow([
          const [1, 2],
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects decimal'),
          ),
        ),
      );
    });

    test('binary column rejects non-list<int> value in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.binary, maxLen: 8)
            .addRow(['abc']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects binary data'),
          ),
        ),
      );
    });

    test('timestamp column rejects invalid value type in addRow', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.timestamp)
            .addRow(['2025-01-01']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('expects timestamp'),
          ),
        ),
      );
    });

    test('type error message includes row number', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow([1]).addRow(['2']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('at row 2'),
          ),
        ),
      );
    });
  });

  group('BulkInsertBuilder', () {
    test('addRow stores list reference (ownership contract)', () {
      final row = <dynamic>[1];
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i32)
          .addRow(row);

      // Ownership contract: mutating source list after addRow affects output.
      row[0] = 7;

      final enc = b.build();
      final view = ByteData.sublistView(enc);

      var o = 0;
      o += 4 + 1; // table length + table char
      o += 4 + 4 + 1 + 1 + 1 + 4; // single column metadata
      expect(view.getUint32(o, Endian.little), equals(1));
      o += 4;
      expect(view.getInt32(o, Endian.little), equals(7));
    });

    test('build keeps final nullability guard for mutated rows', () {
      final row = <dynamic>[1];
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i32)
          .addRow(row);

      row[0] = null;

      expect(
        b.build,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('at row 1'),
          ),
        ),
      );
    });

    test('I32 single column non-nullable roundtrip structure', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i32)
          .addRow([1]).addRow([2]);
      expect(b.tableName, equals('t'));
      expect(b.columnNames, equals(['a']));
      expect(b.rowCount, equals(2));

      final enc = b.build();
      final view = ByteData.sublistView(enc);

      var o = 0;
      expect(view.getUint32(o, Endian.little), equals(1));
      o += 4;
      expect(enc[o], equals(0x74));
      o += 1;
      expect(view.getUint32(o, Endian.little), equals(1));
      o += 4;
      expect(view.getUint32(o, Endian.little), equals(1));
      o += 4;
      expect(enc[o], equals(0x61));
      o += 1;
      expect(enc[o], equals(0));
      o += 1;
      expect(enc[o], equals(0));
      o += 1;
      expect(view.getUint32(o, Endian.little), equals(0));
      o += 4;
      expect(view.getUint32(o, Endian.little), equals(2));
      o += 4;
      expect(view.getInt32(o, Endian.little), equals(1));
      o += 4;
      expect(view.getInt32(o, Endian.little), equals(2));
      expect(o + 4, equals(enc.length));
    });

    test('I32 nullable with null bitmap', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i32, nullable: true)
          .addRow([1]).addRow([null]).addRow([3]);
      final enc = b.build();
      final view = ByteData.sublistView(enc);

      var o = 0;
      o += 4 + 1;
      o += 4 + 4 + 1 + 1 + 1 + 4;
      expect(view.getUint32(o, Endian.little), equals(3));
      o += 4;
      expect(enc.length > o + 1, isTrue);
      final nullBitmapSize = (3 / 8).ceil();
      expect(nullBitmapSize, equals(1));
      final bitmap = enc[o];
      o += 1;
      expect((bitmap & (1 << 1)) != 0, isTrue);
      expect(view.getInt32(o, Endian.little), equals(1));
      o += 4;
      expect(view.getInt32(o, Endian.little), equals(0));
      o += 4;
      expect(view.getInt32(o, Endian.little), equals(3));
    });

    test('Text column with maxLen padding', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('x', BulkColumnType.text, maxLen: 10)
          .addRow(['hi']).addRow(['world']);
      final enc = b.build();
      final view = ByteData.sublistView(enc);

      var o = 0;
      o += 4 + 1 + 4 + 4 + 1 + 1 + 1 + 4;
      expect(view.getUint32(o, Endian.little), equals(2));
      o += 4;
      expect(enc.sublist(o, o + 2), equals([104, 105]));
      for (var i = 0; i < 8; i++) {
        expect(enc[o + 2 + i], equals(0));
      }
      o += 10;
      expect(enc.sublist(o, o + 5), equals([119, 111, 114, 108, 100]));
      for (var i = 0; i < 5; i++) {
        expect(enc[o + 5 + i], equals(0));
      }
    });

    test('build throws when table empty', () {
      expect(
        () => BulkInsertBuilder()
            .addColumn('a', BulkColumnType.i32)
            .addRow([1]).build(),
        throwsA(isA<StateError>()),
      );
    });

    test('build throws when no columns', () {
      expect(
        () => BulkInsertBuilder().table('t').addRow([1]).build(),
        throwsA(isA<StateError>()),
      );
    });

    test('addRow throws when column count mismatch', () {
      expect(
        () => BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.i32)
            .addRow([1, 2]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
