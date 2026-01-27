import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Timeout Integration Tests', () {
    late ServiceLocator locator;
    late OdbcService service;

    String? getConnectionString() => getTestEnv('ODBC_TEST_DSN');

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      await locator.service.initialize();
      service = locator.service;
    });

    test('connect with ConnectionOptions loginTimeout succeeds when DSN valid',
        () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final result = await service.connect(
        dsn,
        options: const ConnectionOptions(
          loginTimeout: Duration(seconds: 30),
        ),
      );

      expect(result.isSuccess(), isTrue);
      result.fold(
        (conn) {
          expect(conn.id, isNotEmpty);
          service.disconnect(conn.id);
        },
        (_) => fail('connect with loginTimeout should succeed'),
      );
    });

    test('connect without options succeeds when DSN valid', () async {
      final dsn = getConnectionString();
      if (dsn == null) return;

      final result = await service.connect(dsn);

      expect(result.isSuccess(), isTrue);
      await result.fold(
        (conn) => service.disconnect(conn.id),
        (_) => fail('connect without options should succeed'),
      );
    });
  });
}
