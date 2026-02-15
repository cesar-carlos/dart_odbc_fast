import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('M2 Validation Tests', () {
    late ServiceLocator locator;
    late String? connectionString;

    setUpAll(() async {
      locator = ServiceLocator()..initialize();
      await locator.service.initialize();
      connectionString = isE2eEnabled() ? getTestEnv('ODBC_TEST_DSN') : null;
    });

    test('binary protocol should work', () {
      final native = locator.nativeConnection;
      expect(native, isNotNull);
    });

    test('streaming should work', () async {
      final dsn = connectionString;
      if (dsn == null) return;

      final connResult = await locator.service.connect(dsn);
      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final native = locator.nativeConnection;
      final stream = native.streamQuery(
        int.parse(connection.id),
        'SELECT 1',
      );

      await for (final chunk in stream) {
        expect(chunk.rowCount, greaterThanOrEqualTo(0));
        break;
      }

      await locator.service.disconnect(connection.id);
    });

    test('structured errors should work', () async {
      if (connectionString == null) {
        return;
      }

      final connResult = await locator.service.connect('INVALID_DSN');

      expect(connResult.isSuccess(), isFalse);
      connResult.fold(
        (_) => fail('Should fail with invalid DSN'),
        (error) {
          expect(error, isA<ConnectionError>());
        },
      );
    });
  });
}
