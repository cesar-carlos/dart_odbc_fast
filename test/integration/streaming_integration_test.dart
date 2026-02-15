// Streaming queries integration test
//
// Tests streamQueryBatched with a real database
//
// Prerequisites: Set ODBC_TEST_DSN in environment variable or .env.
// Execute: dart test test/integration/streaming_integration_test.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Streaming queries integration tests', () {
    late NativeOdbcConnection native;
    var connId = 0;

    setUpAll(() async {
      final dsn = getTestEnv('ODBC_TEST_DSN') ?? getTestEnv('ODBC_DSN');
      if (dsn == null || dsn.isEmpty) {
        print('Skipping integration tests: ODBC_TEST_DSN not set');
        return;
      }

      native = NativeOdbcConnection();
      final initResult = native.initialize();
      if (!initResult) {
        throw Exception('ODBC environment initialization failed');
      }

      connId = native.connect(dsn);
      if (connId == 0) {
        throw Exception('Connection failed: ${native.getError()}');
      }

      // Create test table
      const createTableSql = '''
        IF OBJECT_ID('streaming_test', 'U') IS NOT NULL
          DROP TABLE streaming_test;

        CREATE TABLE streaming_test (
          id INT IDENTITY(1,1) PRIMARY KEY,
          name NVARCHAR(100) NOT NULL,
          value DECIMAL(10,2)
        )
      ''';

      final createStmt = native.prepare(connId, createTableSql);
      if (createStmt == 0) {
        throw Exception('Prepare create failed: ${native.getError()}');
      }

      final createResult =
          native.executePrepared(createStmt, const <ParamValue>[], 0, 1000);
      if (createResult == null) {
        throw Exception('Table creation failed: ${native.getError()}');
      }

      native.closeStatement(createStmt);

      // Insert test data
      const insertSql =
          'INSERT INTO streaming_test (name, value) VALUES (?, ?)';
      for (var i = 1; i <= 100; i++) {
        final insertStmt = native.prepare(connId, insertSql);
        if (insertStmt != 0) {
          native
            ..executePrepared(
              insertStmt,
              [
                ParamValueString('Item_$i'),
                ParamValueDecimal((i * 1.5).toStringAsFixed(2)),
              ],
              0,
              1000,
            )
            ..closeStatement(insertStmt);
        }
      }
    });

    tearDownAll(() {
      if (connId != 0) {
        native.disconnect(connId);
      }
    });

    test('streamQueryBatched returns data in chunks', () async {
      const selectSql = 'SELECT id, name, value FROM streaming_test';

      var totalRows = 0;
      var chunkCount = 0;
      final stream = native.streamQueryBatched(
        connId,
        selectSql,
        fetchSize: 20,
      );

      await for (final chunk in stream) {
        chunkCount++;
        final rowCount = chunk.rowCount;
        totalRows += rowCount;

        expect(rowCount, greaterThan(0));
        expect(rowCount, lessThanOrEqualTo(20));
      }

      expect(chunkCount, greaterThan(1));
      expect(totalRows, 100);
    });

    test('streamQuery with custom chunk size works', () async {
      const selectSql = 'SELECT id, name, value FROM streaming_test';

      var totalRows = 0;
      var chunkCount = 0;
      final stream = native.streamQuery(
        connId,
        selectSql,
        chunkSize: 25,
      );

      await for (final chunk in stream) {
        chunkCount++;
        totalRows += chunk.rowCount;
      }

      // streamQuery aggregates protocol chunks and yields a parsed result set.
      expect(chunkCount, equals(1));
      expect(totalRows, 100);
    });

    test('streamQueryBatched with large fetchSize returns fewer chunks',
        () async {
      const selectSql = 'SELECT id, name, value FROM streaming_test';

      var chunkCount = 0;
      final stream = native.streamQueryBatched(
        connId,
        selectSql,
        fetchSize: 100,
      );

      await for (final _ in stream) {
        chunkCount++;
      }

      expect(chunkCount, 1);
    });

    test('Streaming query handles empty result set', () async {
      const createEmptyTableSql = '''
        IF OBJECT_ID('empty_table', 'U') IS NOT NULL
          DROP TABLE empty_table;

        CREATE TABLE empty_table (
          id INT IDENTITY(1,1) PRIMARY KEY,
          name NVARCHAR(100)
        )
      ''';

      final createStmt = native.prepare(connId, createEmptyTableSql);
      if (createStmt == 0) {
        fail('Prepare create failed: ${native.getError()}');
      }

      final createResult =
          native.executePrepared(createStmt, const <ParamValue>[], 0, 1000);
      if (createResult == null) {
        fail('Table creation failed: ${native.getError()}');
      }

      native.closeStatement(createStmt);

      const selectSql = 'SELECT * FROM empty_table';

      var rowCount = 0;
      final stream = native.streamQueryBatched(
        connId,
        selectSql,
        fetchSize: 10,
      );

      await for (final chunk in stream) {
        rowCount += chunk.rowCount;
      }

      expect(rowCount, 0);
    });

    test('Streaming query with WHERE clause filters results', () async {
      const selectSql = 'SELECT * FROM streaming_test WHERE id <= 50';

      var totalRows = 0;
      final stream = native.streamQueryBatched(
        connId,
        selectSql,
        fetchSize: 20,
      );

      await for (final chunk in stream) {
        totalRows += chunk.rowCount;
      }

      expect(totalRows, 50);
    });
  });
}
