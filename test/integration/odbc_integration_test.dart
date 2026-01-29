import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('ODBC Integration Tests', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      // initialize() returns void, so cascade cannot be used in assignment.
      // ignore: cascade_invocations
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

    test('should connect to database', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) {
        return;
      }
      if (!shouldRunE2e) {
        return;
      }

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(connectionString);

      expect(connResult.isSuccess(), isTrue);
      Connection? conn;
      connResult.fold(
        (connection) {
          expect(connection.id, isNotEmpty);
          expect(connection.isActive, isTrue);
          conn = connection;
        },
        (failure) {
          final error = failure as OdbcError;
          fail('Connection failed: ${error.message}');
        },
      );
      if (conn != null) {
        await service.disconnect(conn!.id);
      }
    });

    test('should handle invalid connection string', () async {
      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect('');

      expect(connResult.isSuccess(), isFalse);
      connResult.fold(
        (success) => fail('Should fail with empty string'),
        (failure) => expect(failure, isA<ValidationError>()),
      );
    });

    test('should disconnect successfully', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;
      if (!shouldRunE2e) return;

      await service.initialize();
      final connResult = await service.connect(connectionString);

      final connection = connResult.getOrElse((_) => throw Exception());

      final disconnectResult = await service.disconnect(connection.id);

      expect(disconnectResult.isSuccess(), isTrue);
    });
  });
}
