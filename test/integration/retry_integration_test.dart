import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Retry Integration Tests', () {
    late ServiceLocator locator;
    late OdbcService service;

    String? getConnectionString() =>
        isE2eEnabled() ? getTestEnv('ODBC_TEST_DSN') : null;

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      await locator.service.initialize();
      service = locator.service;
    });

    test('withRetry around connect succeeds when DSN is valid', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final result = await service.withRetry(() => service.connect(dsn));

      expect(result.isSuccess(), isTrue);
      result.fold(
        (conn) {
          expect(conn.id, isNotEmpty);
          service.disconnect(conn.id);
        },
        (_) => fail('withRetry(connect) should succeed'),
      );
    });

    test(
        'withRetry does not retry on ValidationError (empty connection string)',
        () async {
      var callCount = 0;
      Future<Result<Connection>> operation() async {
        callCount++;
        return service.connect('');
      }

      final result = await service.withRetry(operation);

      expect(result.isSuccess(), isFalse);
      expect(result.exceptionOrNull(), isNotNull);
      expect(callCount, 1);
    });

    test('withRetry around executeQuery succeeds when connection is valid',
        () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final connResult = await service.connect(dsn);
      if (connResult.fold((_) => false, (_) => true)) return;

      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final queryResult = await service.withRetry(
        () => service.executeQuery(connection.id, 'SELECT 1 AS n'),
      );

      expect(queryResult.isSuccess(), isTrue);
      queryResult.fold(
        (qr) => expect(qr.rows, isNotEmpty),
        (_) => fail('withRetry(executeQuery) should succeed'),
      );
      await service.disconnect(connection.id);
    });
  });
}
