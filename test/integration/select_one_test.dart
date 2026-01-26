import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  test('SELECT 1 should return 1', () async {
    final locator = ServiceLocator();
    locator.initialize();
    final service = locator.service;

    final connectionString = getTestEnv('ODBC_TEST_DSN');
    if (connectionString == null) {
      print('Skipping test: ODBC_TEST_DSN not set');
      return;
    }

    final initResult = await service.initialize();
    expect(initResult.isSuccess(), isTrue);

    final connResult = await service.connect(connectionString);
    expect(connResult.isSuccess(), isTrue);

    final connection =
        connResult.getOrElse((_) => throw Exception('Failed to connect'));

    print('Connected successfully: ${connection.id}');

    try {
      // Execute SELECT 1
      final queryResult =
          await service.executeQuery(connection.id, 'SELECT 1 AS value');

      expect(queryResult.isSuccess(), isTrue,
          reason: 'SELECT 1 query should succeed',);

      await queryResult.fold(
        (result) async {
          print('✓ Query executed successfully');
          print('  Columns: ${result.columns}');
          print('  Rows: ${result.rowCount}');
          print('  Data: ${result.rows}');

          // Verify the result
          expect(result.rowCount, equals(1), reason: 'Should return 1 row');
          expect(result.columns, isNotEmpty, reason: 'Should have columns');
          expect(result.rows, isNotEmpty, reason: 'Should have data');
          expect(result.rows.first, isNotEmpty, reason: 'Row should have data');

          print('✓ SELECT 1 test passed: returned ${result.rows.first}');
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
}
