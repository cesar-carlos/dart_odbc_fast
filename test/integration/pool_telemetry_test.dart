import 'package:test/test.dart';
import 'package:odbc_fast/odbc_fast.dart';

import '../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('ODBC Integration Tests - Pool Telemetry (CONN-002)', () {
    late ServiceLocator locator;
    late OdbcService service;

    setUpAll(() async {
      locator = ServiceLocator();
      locator.initialize();
      service = locator.service;

      await service.initialize();
    });

    tearDown(() async {
      final conn = locator.service.activeConnection;
      if (conn != null) {
        await service.disconnect(conn!.id);
      }
    });

    test('should track pool metrics after connect', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');
      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      // Initialize and connect
      await service.initialize();
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final connection = connResult.getOrElse((_) => throw Exception());

      // Get metrics - should have 1 active connection
      final metrics = service.getPoolMetrics();
      expect(metrics.activeConnections, equals(1));
      expect(metrics.totalConnections, equals(1));
    });

    test('should track multiple connections in pool', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect multiple times from same "pool"
      final conn1Result = await service.connect(connectionString);
      expect(conn1Result.isSuccess(), isTrue);
      final conn1 = conn1Result.getOrElse((_) => throw Exception());

      final conn2Result = await service.connect(connectionString);
      expect(conn2Result.isSuccess(), isTrue);
      final conn2 = conn2Result.getOrElse((_) => throw Exception());

      final conn3Result = await service.connect(connectionString);
      expect(conn3Result.isSuccess(), isTrue);
      final conn3 = conn3Result.getOrElse((_) => throw Exception());

      // Get metrics - should have 3 total, 3 active (or fewer if driver shares handles)
      final metrics = service.getPoolMetrics();
      expect(metrics.totalConnections, greaterThanOrEqualTo(3));
      expect(metrics.activeConnections, greaterThanOrEqualTo(3));
      expect(metrics.totalConnections, lessThanOrEqualTo(10)); // Max pool size
    });

    test('should track pool reuse', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect and disconnect twice
      final conn1Result = await service.connect(connectionString);
      expect(conn1Result.isSuccess(), isTrue);
      final conn1 = conn1Result.getOrElse((_) => throw Exception());

      await service.disconnect(conn1.id);
      expect(await service.disconnect(conn1.id).isSuccess(), isFalse); // Already disconnected

      // Connect again - should reuse connection from pool
      final conn2Result = await service.connect(connectionString);
      expect(conn2Result.isSuccess(), isTrue);
      final conn2 = conn2Result.getOrElse((_) => throw Exception());

      final metrics = service.getPoolMetrics();
      // Pool should have reused the connection
      expect(metrics.totalConnections, lessThan(2));
      expect(metrics.activeConnections, equals(1));
    });

    test('should track connection lifetime', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Connect and check lifetime
      final connResult = await service.connect(connectionString);
      expect(connResult.isSuccess(), isTrue);
      final conn = connResult.getOrElse((_) => throw Exception());

      final metrics1 = service.getPoolMetrics();
      expect(metrics1.createdAt, isNotNull);

      // Wait a bit to accumulate lifetime time
      await Future.delayed(Duration(milliseconds: 100));

      // Disconnect
      await service.disconnect(conn.id);
      final metrics2 = service.getPoolMetrics();
      expect(metrics2.totalConnections, equals(0)); // No active connections
      expect(metrics2.createdAt, isNull); // No connections with timestamp

      // Total lifetime should be tracked
      expect(metrics1.totalConnections, equals(1)); // Total should still be 1
    });

    test('should track pool metrics accurately', () async {
      final shouldRunE2e = isE2eEnabled();
      final connectionString = getTestEnv('ODBC_TEST_DSN');

      if (connectionString == null) return;

      if (!shouldRunE2e) return;

      await service.initialize();

      // Perform multiple operations
      for (int i = 0; i < 5; i++) {
        final connResult = await service.connect(connectionString);
        expect(connResult.isSuccess(), isTrue);
        final conn = connResult.getOrElse((_) => throw Exception());
        await service.disconnect(conn.id);
      }

      // Check metrics accuracy
      final metrics = service.getPoolMetrics();
      expect(metrics.totalConnections, equals(5)); // 5 connections created
      expect(metrics.activeConnections, equals(0)); // All disconnected
    });
  });
}
