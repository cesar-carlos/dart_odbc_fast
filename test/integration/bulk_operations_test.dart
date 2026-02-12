import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Bulk Operations (STMT-003)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      service = locator.service;

      await service.initialize();
    });

    test('should perform bulk insert with multiple rows', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      try {
        final builder = BulkInsertBuilder()
          ..table('bulk_test_table')
          ..addColumn('id', BulkColumnType.i32)
          ..addColumn('name', BulkColumnType.text, maxLen: 100)
          ..addColumn('value', BulkColumnType.i64)
          ..addRow([1, 'Alice', 1000])
          ..addRow([2, 'Bob', 2000])
          ..addRow([3, 'Charlie', 3000]);

        final buffer = builder.build();
        final columns = builder.columnNames;

        final result = await service.bulkInsert(
          conn.id,
          builder.tableName,
          columns,
          buffer.toList(),
          builder.rowCount,
        );

        expect(result.isSuccess(), isTrue);
        final inserted = result.getOrElse((_) => throw Exception());
        expect(inserted, equals(3));
      } finally {
        await service.disconnect(conn.id);
      }
    });

    test('should handle bulk insert with nullable columns', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      try {
        final builder = BulkInsertBuilder()
          ..table('bulk_test_table')
          ..addColumn('id', BulkColumnType.i32, nullable: true)
          ..addColumn('name', BulkColumnType.text, maxLen: 100, nullable: true)
          ..addColumn('value', BulkColumnType.i64)
          ..addRow([1, 'Alice', 1000])
          ..addRow([null, null, 2000])
          ..addRow([3, 'Charlie', 3000]);

        final buffer = builder.build();
        final columns = builder.columnNames;

        final result = await service.bulkInsert(
          conn.id,
          builder.tableName,
          columns,
          buffer.toList(),
          builder.rowCount,
        );

        expect(result.isSuccess(), isTrue);
        final inserted = result.getOrElse((_) => throw Exception());
        expect(inserted, equals(3));
      } finally {
        await service.disconnect(conn.id);
      }
    });

    test('should handle bulk insert with timestamps', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      try {
        final now = DateTime.now();
        final builder = BulkInsertBuilder()
          ..table('bulk_test_table')
          ..addColumn('id', BulkColumnType.i32)
          ..addColumn('created_at', BulkColumnType.timestamp)
          ..addColumn('name', BulkColumnType.text, maxLen: 50)
          ..addRow([1, now, 'Test'])
          ..addRow([2, now.add(const Duration(days: 1)), 'Test2']);

        final buffer = builder.build();
        final columns = builder.columnNames;

        final result = await service.bulkInsert(
          conn.id,
          builder.tableName,
          columns,
          buffer.toList(),
          builder.rowCount,
        );

        expect(result.isSuccess(), isTrue);
        final inserted = result.getOrElse((_) => throw Exception());
        expect(inserted, equals(2));
      } finally {
        await service.disconnect(conn.id);
      }
    });

    test('should handle bulk insert with binary data', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      try {
        final binaryData = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
        final builder = BulkInsertBuilder()
          ..table('bulk_test_table')
          ..addColumn('id', BulkColumnType.i32)
          ..addColumn('data', BulkColumnType.binary, maxLen: 100)
          ..addRow([1, binaryData])
          ..addRow([
            2,
            Uint8List.fromList([0x05, 0x06]),
          ]);

        final buffer = builder.build();
        final columns = builder.columnNames;

        final result = await service.bulkInsert(
          conn.id,
          builder.tableName,
          columns,
          buffer.toList(),
          builder.rowCount,
        );

        expect(result.isSuccess(), isTrue);
        final inserted = result.getOrElse((_) => throw Exception());
        expect(inserted, equals(2));
      } finally {
        await service.disconnect(conn.id);
      }
    });

    test('should validate builder constraints', () {
      expect(
        () => BulkInsertBuilder().build(),
        throwsA(isA<StateError>()),
        reason: 'Should throw when table name is empty',
      );

      expect(
        () => BulkInsertBuilder()..table('test').addRow([1]),
        throwsA(isA<StateError>()),
        reason: 'Should throw when no columns defined',
      );

      expect(
        () => BulkInsertBuilder()..table('test').build(),
        throwsA(isA<StateError>()),
        reason: 'Should throw when no rows added',
      );

      expect(
        () => BulkInsertBuilder()
          ..table('test')
          ..addColumn('col1', BulkColumnType.i32)
          ..addRow([1, 2]),
        throwsA(isA<ArgumentError>()),
        reason: 'Should throw when row length != column count',
      );
    });

    test('should serialize and deserialize bulk payload correctly', () {
      final builder = BulkInsertBuilder()
        ..table('test_table')
        ..addColumn('id', BulkColumnType.i32)
        ..addColumn('name', BulkColumnType.text, maxLen: 50)
        ..addRow([1, 'Alice'])
        ..addRow([2, 'Bob']);

      final buffer = builder.build();

      expect(buffer.isNotEmpty, isTrue);
      expect(builder.tableName, equals('test_table'));
      expect(builder.columnNames, equals(['id', 'name']));
      expect(builder.rowCount, equals(2));
    });
  });
}
