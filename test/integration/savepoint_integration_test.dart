import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Savepoint Integration Tests', () {
    late ServiceLocator locator;
    late OdbcService service;

    String? getConnectionString() => getTestEnv('ODBC_TEST_DSN');

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      await locator.service.initialize();
      service = locator.service;
    });

    test('savepoint rollback partial changes', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final connResult = await service.connect(dsn);
      if (connResult.fold((_) => false, (_) => true)) return;

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final beginResult = await service.beginTransaction(
        connection.id,
        IsolationLevel.readCommitted,
      );
      if (beginResult.fold((_) => false, (_) => true)) {
        await service.disconnect(connection.id);
        return;
      }

      final txnId = beginResult.getOrElse((_) => throw Exception('no txn'));

      try {
        await service.executeQuery(
          connection.id,
          'CREATE TABLE sp_int_test (id INT)',
        );

        await service.executeQuery(
          connection.id,
          'INSERT INTO sp_int_test VALUES (1)',
        );

        final createSp =
            await service.createSavepoint(connection.id, txnId, 'sp1');
        if (createSp.fold((_) => false, (_) => true)) {
          await service.rollbackTransaction(connection.id, txnId);
          await service.disconnect(connection.id);
          return;
        }

        await service.executeQuery(
          connection.id,
          'INSERT INTO sp_int_test VALUES (2)',
        );

        final rollbackSp =
            await service.rollbackToSavepoint(connection.id, txnId, 'sp1');
        if (rollbackSp.fold((_) => false, (_) => true)) {
          await service.rollbackTransaction(connection.id, txnId);
          await service.disconnect(connection.id);
          return;
        }

        await service.executeQuery(
          connection.id,
          'INSERT INTO sp_int_test VALUES (3)',
        );

        final commitResult =
            await service.commitTransaction(connection.id, txnId);
        expect(commitResult.isSuccess(), isTrue);

        final queryResult = await service.executeQuery(
          connection.id,
          'SELECT id FROM sp_int_test ORDER BY id',
        );
        expect(queryResult.isSuccess(), isTrue);

        queryResult.fold(
          (result) {
            expect(result.rowCount, equals(2));
            expect(result.rows[0][0], equals(1));
            expect(result.rows[1][0], equals(3));
          },
          (_) => fail('Query failed'),
        );

        await service.executeQuery(
          connection.id,
          'DROP TABLE sp_int_test',
        );
      } finally {
        await service.disconnect(connection.id);
      }
    });

    test('savepoint release', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final connResult = await service.connect(dsn);
      if (connResult.fold((_) => false, (_) => true)) return;

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final beginResult = await service.beginTransaction(
        connection.id,
        IsolationLevel.readCommitted,
      );
      if (beginResult.fold((_) => false, (_) => true)) {
        await service.disconnect(connection.id);
        return;
      }

      final txnId = beginResult.getOrElse((_) => throw Exception('no txn'));

      try {
        final createSp =
            await service.createSavepoint(connection.id, txnId, 'sp_r');
        expect(createSp.isSuccess(), isTrue);

        final releaseSp =
            await service.releaseSavepoint(connection.id, txnId, 'sp_r');
        expect(releaseSp.isSuccess(), isTrue);

        await service.commitTransaction(connection.id, txnId);
      } finally {
        await service.disconnect(connection.id);
      }
    });
  });
}
