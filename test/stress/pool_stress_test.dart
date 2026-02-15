import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Pool Stress Tests', () {
    late ServiceLocator locator;
    late String? connectionString;

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      await locator.service.initialize();
      connectionString = getTestEnv('ODBC_TEST_DSN');
    });

    test(
      'should handle 10 concurrent connections',
      () async {
        final dsn = connectionString;
        if (dsn == null) return;

        final connections = <Connection>[];

        for (var i = 0; i < 10; i++) {
          final connResult = await locator.service.connect(dsn);
          connResult.fold(
            connections.add,
            (error) {
              final errorObj = error as OdbcError;
              fail('Connection $i failed: ${errorObj.message}');
            },
          );
        }

        expect(connections.length, equals(10));

        for (final conn in connections) {
          final disconnectResult = await locator.service.disconnect(conn.id);
          expect(disconnectResult.isSuccess(), isTrue);
        }
      },
      skip: runSkippedTests ? null : 'Stress test - runs too long',
    );

    test(
      'should handle rapid connect/disconnect cycles',
      () async {
        final dsn = connectionString;
        if (dsn == null) return;

        for (var i = 0; i < 50; i++) {
          final connResult = await locator.service.connect(dsn);
          final connection =
              connResult.getOrElse((_) => throw Exception('Failed to connect'));
          final disconnectResult =
              await locator.service.disconnect(connection.id);
          expect(disconnectResult.isSuccess(), isTrue);
        }
      },
      skip: runSkippedTests ? null : 'Stress test - runs too long',
    );
  });
}
