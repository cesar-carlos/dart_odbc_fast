import 'dart:typed_data';
import 'package:test/test.dart';

import 'package:odbc_fast/infrastructure/native/protocol/bulk_insert_builder.dart';

void main() {
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
