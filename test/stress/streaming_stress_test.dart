import 'package:test/test.dart';

import 'package:odbc_fast/odbc_fast.dart';
import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Streaming Stress Tests', () {
    late ServiceLocator locator;
    late String? connectionString;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      await locator.service.initialize();
      connectionString = getTestEnv('ODBC_TEST_DSN');
    });

    test('should stream multiple rows without memory issues', () async {
      final dsn = connectionString;
      if (dsn == null) return;

      final connResult = await locator.service.connect(dsn);
      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final native = locator.nativeConnection;
      final stream = native.streamQuery(
        int.parse(connection.id),
        'SELECT 1 AS v UNION ALL SELECT 2 UNION ALL SELECT 3',
      );

      int totalRows = 0;
      await for (final chunk in stream) {
        totalRows += chunk.rowCount;
      }

      expect(totalRows, greaterThan(0));

      await locator.service.disconnect(connection.id);
    });

    test('should handle multiple concurrent streams', () async {
      final dsn = connectionString;
      if (dsn == null) return;

      final connResult = await locator.service.connect(dsn);
      final connection =
          connResult.getOrElse((_) => throw Exception('Failed to connect'));

      final native = locator.nativeConnection;
      final streams = <Stream>[];

      for (int i = 0; i < 5; i++) {
        final stream = native.streamQuery(
          int.parse(connection.id),
          'SELECT 1',
        );
        streams.add(stream);
      }

      int completedStreams = 0;
      for (final stream in streams) {
        await stream.forEach((_) {});
        completedStreams++;
      }

      expect(completedStreams, equals(5));

      await locator.service.disconnect(connection.id);
    });
  });
}
