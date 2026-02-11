import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Connection Lifecycle (CONN-001)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      // initialize() returns void, so cascade cannot be used in assignment.
      // ignore: cascade_invocations
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    test('should initialize environment', () async {
      final result = await service.initialize();

      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) => expect(success, equals(unit)),
        (failure) {
          final error = failure as OdbcError;
          fail('Should not fail: ${error.message}');
        },
      );
    });

    test('should connect to database', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);

      connResult.fold(
        (connection) {
          expect(connection.id, isNotEmpty);
          expect(connection.isActive, isTrue);
        },
        (failure) {
          final error = failure as OdbcError;
          fail('Connection failed: ${error.message}');
        },
      );
    });

    test('should handle invalid connection string', () async {
      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect('');
      expect(connResult.isSuccess(), isFalse);

      connResult.fold(
        (success) => fail('Should fail with empty connection string'),
        (failure) {
          final error = failure as OdbcError;
          expect(error, isA<ValidationError>());
        },
      );
    });

    test('should disconnect successfully', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      final initResult = await service.initialize();
      expect(initResult.isSuccess(), isTrue);

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);

      final disconnectResult = await service
          .disconnect(connResult.getOrElse((_) => throw Exception()).id);
      expect(disconnectResult.isSuccess(), isTrue);
    });

    test('should handle multiple connect/disconnect cycles', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // First connect
      final conn1 = await service.connect(connectionString);
      expect(conn1.isSuccess(), isTrue);
      final connection1 = conn1.getOrElse((_) => throw Exception());

      // Disconnect first connection
      final disconnect1 = await service.disconnect(connection1.id);
      expect(disconnect1.isSuccess(), isTrue);

      // Second connect (should succeed)
      final conn2 = await service.connect(connectionString);
      expect(conn2.isSuccess(), isTrue);
      final connection2 = conn2.getOrElse((_) => throw Exception());

      // Disconnect second connection
      final disconnect2 = await service.disconnect(connection2.id);
      expect(disconnect2.isSuccess(), isTrue);
    });

    test('should get connection info from active connection', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Test that connection has metadata
      expect(connection.id, isNotEmpty);
      expect(connection.connectionString, equals(connectionString));
      expect(connection.isActive, isTrue);
    });
  });
}
