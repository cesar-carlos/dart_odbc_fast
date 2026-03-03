// Integration tests for OdbcService.
///
/// These tests verify that OdbcService operations work correctly.
library;

import 'dart:io';

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart'
    show loadOdbcLibraryFromPath;
import 'package:test/test.dart';

import '../../helpers/load_env.dart';
import '../../helpers/mock_odbc_repository.dart';

void main() {
  loadTestEnv();
  final runningOnCi =
      (Platform.environment['CI'] ?? '').toLowerCase() == 'true';
  group('OdbcService basic operations', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('Initialize service', () async {
      final result = await service.initialize();
      expect(result.isSuccess(), isTrue);
      expect(service.isInitialized(), isTrue);
      expect(mockRepo.initializeCalled, isTrue);
    });

    test('Initialize service with custom library path', () async {
      final sep = Platform.pathSeparator;
      final name = Platform.isWindows ? 'odbc_engine.dll' : 'libodbc_engine.so';
      final customPath =
          '${Directory.current.path}${sep}native${sep}target${sep}release'
          '$sep$name';
      final lib = loadOdbcLibraryFromPath(customPath);
      expect(lib, isNotNull);
    });

    test('Connect operation', () async {
      await service.initialize();
      final result = await service.connect('test-connection-string');
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()?.id, isNotEmpty);
      expect(mockRepo.connectCalled, isTrue);
    });

    test('Disconnect operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final disconnectResult =
          await service.disconnect(connResult.getOrNull()!.id);
      expect(disconnectResult.isSuccess(), isTrue);
      expect(mockRepo.disconnectCalled, isTrue);
    });

    test('ExecuteQueryParams operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryParams(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = ?',
        [1],
      );
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!.rows.length, equals(1));
      expect(mockRepo.executeQueryParamsCalled, isTrue);
    });

    test('StreamQuery operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final chunks = await service
          .streamQuery(connResult.getOrNull()!.id, 'SELECT * FROM users')
          .toList();

      expect(chunks, isNotEmpty);
      expect(chunks.first.isSuccess(), isTrue);
      expect(mockRepo.streamQueryCalled, isTrue);
    });

    test('PrepareNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.prepareNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.prepareNamedCalled, isTrue);
    });

    test('ExecutePreparedNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final stmtResult = await service.prepareNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
      );
      final result = await service.executePreparedNamed(
        connResult.getOrNull()!.id,
        stmtResult.getOrNull()!,
        {'id': 1},
        null,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.executePreparedNamedCalled, isTrue);
    });

    test('ExecuteQueryNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
        {'id': 1},
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.executeQueryNamedCalled, isTrue);
    });

    test('ExecuteQueryMultiFull operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryMultiFull(
        connResult.getOrNull()!.id,
        'SELECT 1; UPDATE users SET active = 1',
      );
      expect(result.isSuccess(), isTrue);
      final multi = result.getOrNull();
      expect(multi, isNotNull);
      expect(multi!.items.length, equals(2));
      expect(multi.resultSets.length, equals(1));
      expect(multi.rowCounts.length, equals(1));
      expect(mockRepo.executeQueryMultiFullCalled, isTrue);
    });

    test('BeginTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), greaterThan(0));
      expect(mockRepo.beginTransactionCalled, isTrue);
    });

    test('CommitTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      final result = await service.commitTransaction(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.commitTransactionCalled, isTrue);
    });

    test('RollbackTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      final result = await service.rollbackTransaction(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.rollbackTransactionCalled, isTrue);
    });

    test('CreateSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.createSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('RollbackToSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.rollbackToSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('ReleaseSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.releaseSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('GetMetrics operation', () async {
      await service.initialize();
      final result = await service.getMetrics();
      expect(result.isSuccess(), isTrue);
      final metrics = result.getOrNull();
      expect(metrics, isNotNull);
      expect(metrics!.queryCount, equals(0)); // No queries executed yet
    });

    test('ClearStatementCache operation', () async {
      await service.initialize();
      final result = await service.clearStatementCache();
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.clearStatementCacheCalled, isTrue);
    });

    test('MetadataCacheEnable operation', () async {
      await service.initialize();
      final result = await service.metadataCacheEnable(
        maxEntries: 128,
        ttlSeconds: 60,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.metadataCacheEnableCalled, isTrue);
    });

    test('MetadataCacheStats operation', () async {
      await service.initialize();
      final result = await service.metadataCacheStats();
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.metadataCacheStatsCalled, isTrue);
      final payload = result.getOrNull();
      expect(payload, isNotNull);
      expect(payload!['hits'], equals(0));
      expect(payload['ttl_secs'], equals(0));
    });

    test('ClearMetadataCache operation', () async {
      await service.initialize();
      final result = await service.clearMetadataCache();
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.clearMetadataCacheCalled, isTrue);
    });

    test('CancelStream operation', () async {
      await service.initialize();
      final result = await service.cancelStream(1);
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.cancelStreamCalled, isTrue);
    });

    test('GetVersion operation', () async {
      await service.initialize();
      final result = await service.getVersion();
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.getVersionCalled, isTrue);
      final payload = result.getOrNull();
      expect(payload, isNotNull);
      expect(payload!['api'], equals('0.1.0'));
      expect(payload['abi'], equals('1.0.0'));
    });

    test('ValidateConnectionString operation (valid)', () async {
      await service.initialize();
      final result = await service.validateConnectionString('DSN=Mock');
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.validateConnectionStringCalled, isTrue);
    });

    test('ValidateConnectionString operation (invalid)', () async {
      await service.initialize();
      final result = await service.validateConnectionString('');
      expect(result.isSuccess(), isFalse);
    });

    test('GetDriverCapabilities operation', () async {
      await service.initialize();
      final result = await service.getDriverCapabilities('DSN=Mock');
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.getDriverCapabilitiesCalled, isTrue);
      final payload = result.getOrNull();
      expect(payload, isNotNull);
      expect(payload!['driver_name'], equals('mock'));
    });

    test('Audit operations', () async {
      await service.initialize();
      final enable = await service.setAuditEnabled(enabled: true);
      expect(enable.isSuccess(), isTrue);
      expect(mockRepo.setAuditEnabledCalled, isTrue);

      final status = await service.getAuditStatus();
      expect(status.isSuccess(), isTrue);
      expect(mockRepo.getAuditStatusCalled, isTrue);
      expect(status.getOrNull()!['enabled'], isTrue);

      final events = await service.getAuditEvents(limit: 10);
      expect(events.isSuccess(), isTrue);
      expect(mockRepo.getAuditEventsCalled, isTrue);

      final clear = await service.clearAuditEvents();
      expect(clear.isSuccess(), isTrue);
      expect(mockRepo.clearAuditEventsCalled, isTrue);
    });

    test('PoolGetStateDetailed operation', () async {
      await service.initialize();
      final result = await service.poolGetStateDetailed(1);
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.poolGetStateDetailedCalled, isTrue);
      final payload = result.getOrNull();
      expect(payload, isNotNull);
      expect(payload!['max_size'], equals(4));
    });

    test('Async query lifecycle operations', () async {
      await service.initialize();
      final start = await service.executeAsyncStart('conn-1', 'SELECT 1');
      expect(start.isSuccess(), isTrue);
      expect(mockRepo.executeAsyncStartCalled, isTrue);

      final poll = await service.asyncPoll(1);
      expect(poll.isSuccess(), isTrue);
      expect(mockRepo.asyncPollCalled, isTrue);
      expect(poll.getOrNull(), equals(1));

      final result = await service.asyncGetResult(1);
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.asyncGetResultCalled, isTrue);
      expect(result.getOrNull()!.rowCount, equals(1));

      final cancel = await service.asyncCancel(1);
      expect(cancel.isSuccess(), isTrue);
      expect(mockRepo.asyncCancelCalled, isTrue);

      final free = await service.asyncFree(1);
      expect(free.isSuccess(), isTrue);
      expect(mockRepo.asyncFreeCalled, isTrue);
    });

    test('Async stream lifecycle operations', () async {
      await service.initialize();
      final start = await service.streamStartAsync('conn-1', 'SELECT 1');
      expect(start.isSuccess(), isTrue);
      expect(mockRepo.streamStartAsyncCalled, isTrue);

      final poll = await service.streamPollAsync(1);
      expect(poll.isSuccess(), isTrue);
      expect(mockRepo.streamPollAsyncCalled, isTrue);
      expect(poll.getOrNull(), equals(1));
    });

    test('StatementOptions functionality - timeout override', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(timeout: Duration(seconds: 5)),
      );
      expect(result.isSuccess(), isTrue);
    });

    test('StatementOptions functionality - fetchSize override', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(fetchSize: 500),
      );
      expect(result.isSuccess(), isTrue);
    });

    test('StatementOptions functionality - both options', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(
          timeout: Duration(seconds: 10),
          fetchSize: 250,
        ),
      );
      expect(result.isSuccess(), isTrue);
    });
  });

  group(
    'OdbcService E2E',
    () {
      ServiceLocator? locator;
      String? dsn;
      String? skipReason;

      setUpAll(() async {
        dsn = getTestEnv('ODBC_TEST_DSN');
        if (dsn == null || dsn!.isEmpty) {
          skipReason = 'ODBC_TEST_DSN not configured';
          return;
        }
        try {
          final sl = ServiceLocator()..initialize(useAsync: true);
          await sl.syncService.initialize();
          await sl.asyncService.initialize();
          locator = sl;
        } on Object catch (e) {
          skipReason = 'Native environment unavailable: $e';
        }
      });

      tearDownAll(() {
        locator?.shutdown();
      });

      test(
        'should connect and execute query with real ODBC',
        () async {
          if (skipReason != null ||
              dsn == null ||
              dsn!.isEmpty ||
              locator == null) {
            return;
          }

          final connResult = await locator!.syncService.connect(dsn!);
          final connection =
              connResult.getOrElse((_) => throw Exception('Failed to connect'));

          final queryResult = await locator!.syncService.executeQueryParams(
            connection.id,
            'SELECT 1',
            [],
          );

          expect(queryResult.isSuccess(), isTrue);
          await locator!.syncService.disconnect(connection.id);
        },
      );

      test(
        'should return unsupported when cancelling prepared statement '
        '(Option B)',
        () async {
          if (skipReason != null ||
              dsn == null ||
              dsn!.isEmpty ||
              locator == null) {
            return;
          }

          final connResult = await locator!.syncService.connect(dsn!);
          final connection =
              connResult.getOrElse((_) => throw Exception('Failed to connect'));

          final prepared = await locator!.syncService.prepare(
            connection.id,
            'SELECT 1',
          );
          final stmtId =
              prepared.getOrElse((_) => throw Exception('Failed to prepare'));

          final cancelResult =
              await locator!.syncService.cancelStatement(connection.id, stmtId);

          expect(cancelResult.isSuccess(), isFalse);
          cancelResult.fold(
            (_) => fail('Expected unsupported cancellation error'),
            (e) {
              expect(e, isA<UnsupportedFeatureError>());
              final unsupported = e as UnsupportedFeatureError;
              expect(
                unsupported.message.toLowerCase(),
                allOf(contains('unsupported'), contains('cancellation')),
              );
              final sqlState = unsupported.sqlState;
              expect(
                sqlState == '0A000' || sqlState == '\x00\x00\x00\x00\x00',
                isTrue,
              );
            },
          );

          await locator!.syncService.closeStatement(connection.id, stmtId);
          await locator!.syncService.disconnect(connection.id);
        },
      );

      test(
        'should reject cancelStatement when statement belongs '
        'to other connection',
        () async {
          if (skipReason != null ||
              dsn == null ||
              dsn!.isEmpty ||
              locator == null) {
            return;
          }

          final connResultA = await locator!.syncService.connect(dsn!);
          final connA = connResultA.getOrElse(
            (_) => throw Exception('Failed to connect A'),
          );
          final connResultB = await locator!.syncService.connect(dsn!);
          final connB = connResultB.getOrElse(
            (_) => throw Exception('Failed to connect B'),
          );

          final prepared = await locator!.syncService.prepare(
            connA.id,
            'SELECT 1',
          );
          final stmtId =
              prepared.getOrElse((_) => throw Exception('Failed to prepare'));

          final cancelResult =
              await locator!.syncService.cancelStatement(connB.id, stmtId);
          expect(cancelResult.isSuccess(), isFalse);
          cancelResult.fold(
            (_) => fail('Expected validation failure'),
            (e) {
              expect(e, isA<ValidationError>());
              expect(
                (e as ValidationError).message,
                contains('does not belong to connection ID'),
              );
            },
          );

          await locator!.syncService.closeStatement(connA.id, stmtId);
          await locator!.syncService.disconnect(connA.id);
          await locator!.syncService.disconnect(connB.id);
        },
      );
    },
    skip: runningOnCi ? 'Disabled in CI workflow (integration/e2e)' : null,
  );
}
