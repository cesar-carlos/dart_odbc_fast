import 'package:test/test.dart';
import 'package:result_dart/result_dart.dart';

import 'package:odbc_fast/odbc_fast.dart';
import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('SQL Server Integration Tests', () {
    late ServiceLocator locator;
    late OdbcService service;

    String? getConnectionString() => getTestEnv('ODBC_TEST_DSN');

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      await locator.service.initialize();
      service = locator.service;
    });

    test('should initialize environment', () async {
      final result = await service.initialize();

      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) => expect(success, unit),
        (failure) {
          final error = failure as OdbcError;
          fail('Should not fail: ${error.message}');
        },
      );
    });

    test('should connect to SQL Server', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(dsn);

      expect(connResult.isSuccess(), isTrue,
          reason:
              'Connection failed. Check if SQL Server is running and credentials are correct.');

      await connResult.fold(
        (connection) async {
          expect(connection.id, isNotEmpty);
          expect(connection.isActive, isTrue);
          print('✓ Connected to SQL Server: ${connection.id}');

          // Cleanup
          final disconnectResult = await service.disconnect(connection.id);
          expect(disconnectResult.isSuccess(), isTrue);
        },
        (failure) async {
          final error = failure as OdbcError;
          fail('Connection failed: ${error.message}'
              '${error.sqlState != null ? ' (SQLSTATE: ${error.sqlState})' : ''}'
              '${error.nativeCode != null ? ' (Code: ${error.nativeCode})' : ''}');
        },
      );
    });

    test('should execute SELECT 1 query', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(dsn);
      expect(connResult.isSuccess(), isTrue);

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      try {
        final queryResult =
            await service.executeQuery(connection.id, 'SELECT 1 AS value');

        expect(queryResult.isSuccess(), isTrue);

        await queryResult.fold(
          (result) async {
            expect(result.rowCount, greaterThan(0));
            expect(result.columns, isNotEmpty);
            expect(result.rows, isNotEmpty);

            print('✓ Query executed successfully');
            print('  Columns: ${result.columns}');
            print('  Rows: ${result.rowCount}');
            print('  First row: ${result.rows.first}');

            // Verify the result
            expect(result.columns.first, equals('value'));
            expect(result.rows.first.first, equals(1));
          },
          (failure) async {
            final error = failure as OdbcError;
            fail('Query execution failed: ${error.message}'
                '${error.sqlState != null ? ' (SQLSTATE: ${error.sqlState})' : ''}');
          },
        );
      } finally {
        await service.disconnect(connection.id);
      }
    });

    test('should execute SELECT with multiple rows', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(dsn);
      expect(connResult.isSuccess(), isTrue);

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      try {
        // Query that returns multiple rows
        final queryResult = await service.executeQuery(
          connection.id,
          'SELECT 1 AS id, \'Hello\' AS message UNION ALL SELECT 2, \'World\'',
        );

        expect(queryResult.isSuccess(), isTrue);

        await queryResult.fold(
          (result) async {
            expect(result.rowCount, equals(2));
            expect(result.columns.length, equals(2));
            expect(result.columns, contains('id'));
            expect(result.columns, contains('message'));

            print('✓ Multi-row query executed successfully');
            print('  Columns: ${result.columns}');
            print('  Rows: ${result.rowCount}');
            for (var i = 0; i < result.rows.length; i++) {
              print('  Row ${i + 1}: ${result.rows[i]}');
            }
          },
          (failure) async {
            final error = failure as OdbcError;
            fail('Query execution failed: ${error.message}');
          },
        );
      } finally {
        await service.disconnect(connection.id);
      }
    });

    test('should use streaming query', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(dsn);
      expect(connResult.isSuccess(), isTrue);

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      try {
        final native = locator.nativeConnection;
        final stream = native.streamQuery(
          int.parse(connection.id),
          'SELECT 1 AS value UNION ALL SELECT 2 UNION ALL SELECT 3',
        );

        var totalRows = 0;
        await for (final chunk in stream) {
          expect(chunk.columns, isNotEmpty);
          expect(chunk.rowCount, greaterThanOrEqualTo(0));

          totalRows += chunk.rowCount;
          print('✓ Chunk received: ${chunk.rowCount} rows');
          print('  Columns: ${chunk.columns.map((c) => c.name).join(", ")}');
        }

        expect(totalRows, greaterThan(0));
        print('✓ Streaming completed: $totalRows total rows');
      } finally {
        await service.disconnect(connection.id);
      }
    });

    test('should handle invalid query gracefully', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(dsn);
      expect(connResult.isSuccess(), isTrue);

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      try {
        final queryResult = await service.executeQuery(
          connection.id,
          'SELECT * FROM nonexistent_table',
        );

        // Should fail with error
        expect(queryResult.isSuccess(), isFalse);

        queryResult.fold(
          (success) => fail('Should have failed'),
          (failure) {
            expect(failure, isA<QueryError>());
            if (failure is OdbcError) {
              print('✓ Invalid query handled correctly: ${failure.message}');
            } else {
              print('✓ Invalid query handled correctly: $failure');
            }
          },
        );
      } finally {
        await service.disconnect(connection.id);
      }
    });
  });
}
