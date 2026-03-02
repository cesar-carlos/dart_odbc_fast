/// Unit tests for [PrimaryKeyInfo], [ForeignKeyInfo], [IndexInfo].
library;

import 'package:odbc_fast/domain/entities/schema_info.dart';
import 'package:test/test.dart';

void main() {
  group('PrimaryKeyInfo', () {
    test('stores all fields correctly', () {
      const info = PrimaryKeyInfo(
        tableName: 'Users',
        columnName: 'id',
        position: 1,
        constraintName: 'PK_Users',
      );
      expect(info.tableName, 'Users');
      expect(info.columnName, 'id');
      expect(info.position, 1);
      expect(info.constraintName, 'PK_Users');
    });
  });

  group('ForeignKeyInfo', () {
    test('stores all fields with defaults for onUpdate and onDelete', () {
      const info = ForeignKeyInfo(
        constraintName: 'FK_Orders_Users',
        fromTable: 'Orders',
        fromColumn: 'user_id',
        toTable: 'Users',
        toColumn: 'id',
      );
      expect(info.constraintName, 'FK_Orders_Users');
      expect(info.fromTable, 'Orders');
      expect(info.fromColumn, 'user_id');
      expect(info.toTable, 'Users');
      expect(info.toColumn, 'id');
      expect(info.onUpdate, '');
      expect(info.onDelete, '');
    });

    test('stores onUpdate and onDelete when provided', () {
      const info = ForeignKeyInfo(
        constraintName: 'FK_Orders_Users',
        fromTable: 'Orders',
        fromColumn: 'user_id',
        toTable: 'Users',
        toColumn: 'id',
        onUpdate: 'CASCADE',
        onDelete: 'SET NULL',
      );
      expect(info.onUpdate, 'CASCADE');
      expect(info.onDelete, 'SET NULL');
    });
  });

  group('IndexInfo', () {
    test('stores all fields with defaults', () {
      const info = IndexInfo(
        indexName: 'IX_Users_email',
        tableName: 'Users',
        columnName: 'email',
      );
      expect(info.indexName, 'IX_Users_email');
      expect(info.tableName, 'Users');
      expect(info.columnName, 'email');
      expect(info.isUnique, false);
      expect(info.isPrimaryKey, false);
      expect(info.ordinalPosition, isNull);
    });

    test('stores isUnique and isPrimaryKey when true', () {
      const info = IndexInfo(
        indexName: 'IX_Users_email',
        tableName: 'Users',
        columnName: 'email',
        isUnique: true,
      );
      expect(info.isUnique, true);
      expect(info.isPrimaryKey, false);
    });

    test('stores ordinalPosition when provided', () {
      const info = IndexInfo(
        indexName: 'IX_Users_name',
        tableName: 'Users',
        columnName: 'name',
        ordinalPosition: 2,
      );
      expect(info.ordinalPosition, 2);
    });
  });
}
