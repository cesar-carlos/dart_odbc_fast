import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';
import 'package:test/test.dart';

/// Baseline tests for bulk insert nullability behavior.
///
/// These tests capture current behavior before refactoring:
/// - Non-nullable columns currently accept null and serialize default values
/// - No validation error is thrown for null in non-nullable columns
void main() {
  group('Phase 2: Non-nullable null validation', () {
    test('non-nullable i32 column throws for null value', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i32)
          .addRow([null]);
      expect(
        b.build,
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

    test('non-nullable text column throws for null value', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.text, maxLen: 10)
          .addRow([null]);
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

    test('non-nullable i64 column throws for null value', () {
      final b = BulkInsertBuilder()
          .table('t')
          .addColumn('a', BulkColumnType.i64)
          .addRow([null]);
      expect(
        b.build,
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
      'non-nullable decimal column throws for null value',
      () {
        final b = BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.decimal, maxLen: 20)
            .addRow([null]);
        expect(
          b.build,
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
      'non-nullable timestamp column throws for null value',
      () {
        final b = BulkInsertBuilder()
            .table('t')
            .addColumn('a', BulkColumnType.timestamp)
            .addRow([null]);
        expect(
          b.build,
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
  });

  group('BulkInsertBuilder', () {
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
