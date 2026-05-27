/// Unit tests for [ColumnMetadata] value semantics.
library;

import 'package:odbc_fast/domain/entities/column_metadata.dart';
import 'package:test/test.dart';

void main() {
  group('ColumnMetadata', () {
    test('should_expose_name_and_odbcType_via_constructor', () {
      const meta = ColumnMetadata(name: 'id', odbcType: 2);
      expect(meta.name, equals('id'));
      expect(meta.odbcType, equals(2));
    });

    test('should_treat_identical_instance_as_equal', () {
      const meta = ColumnMetadata(name: 'id', odbcType: 2);
      expect(identical(meta, meta), isTrue);
      expect(meta == meta, isTrue);
    });

    test('should_be_equal_when_name_and_odbcType_match', () {
      const a = ColumnMetadata(name: 'id', odbcType: 2);
      const b = ColumnMetadata(name: 'id', odbcType: 2);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('should_not_be_equal_when_name_differs', () {
      const a = ColumnMetadata(name: 'id', odbcType: 2);
      const b = ColumnMetadata(name: 'other', odbcType: 2);
      expect(a, isNot(equals(b)));
    });

    test('should_not_be_equal_when_odbcType_differs', () {
      const a = ColumnMetadata(name: 'id', odbcType: 2);
      const b = ColumnMetadata(name: 'id', odbcType: 3);
      expect(a, isNot(equals(b)));
    });

    test('should_not_be_equal_to_unrelated_type', () {
      const meta = ColumnMetadata(name: 'id', odbcType: 2);
      // Covers the `is ColumnMetadata` guard in `operator ==`.
      expect(meta == Object(), isFalse);
    });

    test('toString should_include_name_and_odbcType', () {
      const meta = ColumnMetadata(name: 'name', odbcType: 1);
      final repr = meta.toString();
      expect(repr, contains('ColumnMetadata'));
      expect(repr, contains('name: name'));
      expect(repr, contains('odbcType: 1'));
    });
  });
}
