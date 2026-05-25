/// Unit tests for [OdbcService] Dart-side validation, defaults, and routing.
library;

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/savepoint_dialect.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

void main() {
  group('OdbcService orchestration (Dart logic)', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    group('executeQuery connection guard', () {
      test(
        'should_return_failure_connection_error_when_executeQuery_has_null_connectionId',
        () async {
          final result = await service.executeQuery('SELECT 1');
          expect(result.isError(), isTrue);
          final err = result.exceptionOrNull();
          expect(err, isA<ConnectionError>());
          expect(
            (err as ConnectionError).message,
            contains('No active connection'),
          );
          expect(mockRepo.executeQueryParamsCalled, isFalse);
        },
      );

      test(
        'should_return_failure_connection_error_when_executeQuery_has_'
        'empty_connectionId',
        () async {
          final result =
              await service.executeQuery('SELECT 1', connectionId: '');
          expect(result.isError(), isTrue);
          expect(result.exceptionOrNull(), isA<ConnectionError>());
          expect(mockRepo.executeQueryParamsCalled, isFalse);
        },
      );
    });

    group('executeQuery param routing', () {
      late String connectionId;

      setUp(() async {
        await service.initialize();
        final conn = await service.connect('DSN=test');
        connectionId = conn.getOrThrow().id;
      });

      test(
        'should_route_to_executeQueryParams_with_empty_params_'
        'when_params_is_null',
        () async {
          final result = await service.executeQuery(
            'SELECT 1',
            connectionId: connectionId,
          );

          expect(result.isSuccess(), isTrue);
          expect(mockRepo.executeQueryParamsCalled, isTrue);
        },
      );

      test(
        'should_route_to_executeQueryParams_when_params_are_nonempty',
        () async {
          mockRepo.executeQueryParamsCalled = false;
          final result = await service.executeQuery(
            'SELECT * FROM t WHERE id = ?',
            params: [42],
            connectionId: connectionId,
          );

          expect(result.isSuccess(), isTrue);
          expect(mockRepo.executeQueryParamsCalled, isTrue);
        },
      );

      test(
        'should_route_to_executeQueryParams_with_empty_list_when_params_empty',
        () async {
          mockRepo.executeQueryParamsCalled = false;
          final result = await service.executeQuery(
            'SELECT 1',
            params: [],
            connectionId: connectionId,
          );

          expect(result.isSuccess(), isTrue);
          expect(mockRepo.executeQueryParamsCalled, isTrue);
        },
      );
    });

    group('beginTransaction defaults', () {
      late String connectionId;

      setUp(() async {
        await service.initialize();
        connectionId = (await service.connect('DSN=test')).getOrThrow().id;
      });

      test(
        'should_apply_beginTransaction_defaults_when_options_omitted',
        () async {
          final result = await service.beginTransaction(connectionId);

          expect(result.isSuccess(), isTrue);
          expect(
            mockRepo.lastBeginIsolationLevel,
            IsolationLevel.readCommitted,
          );
          expect(mockRepo.lastBeginSavepointDialect, SavepointDialect.auto);
          expect(mockRepo.lastBeginAccessMode, TransactionAccessMode.readWrite);
          expect(mockRepo.lastBeginLockTimeout, isNull);
        },
      );

      test(
        'should_forward_beginTransaction_options_to_repository',
        () async {
          await service.beginTransaction(
            connectionId,
            isolationLevel: IsolationLevel.repeatableRead,
            savepointDialect: SavepointDialect.sql92,
            accessMode: TransactionAccessMode.readOnly,
            lockTimeout: const Duration(seconds: 2),
          );

          expect(
            mockRepo.lastBeginIsolationLevel,
            IsolationLevel.repeatableRead,
          );
          expect(
            mockRepo.lastBeginSavepointDialect,
            SavepointDialect.sql92,
          );
          expect(
            mockRepo.lastBeginAccessMode,
            TransactionAccessMode.readOnly,
          );
          expect(
            mockRepo.lastBeginLockTimeout,
            const Duration(seconds: 2),
          );
        },
      );
    });

    group('error propagation', () {
      test(
        'should_propagate_disconnect_failure_when_connection_id_mismatches',
        () async {
          await service.initialize();
          final result = await service.disconnect('wrong-id');

          expect(result.isError(), isTrue);
          expect(result.exceptionOrNull(), isA<ConnectionError>());
          expect(mockRepo.disconnectCalled, isTrue);
        },
      );

      test(
        'should_propagate_unsupported_error_when_cancelStatement_fails',
        () async {
          await service.initialize();
          final result = await service.cancelStatement('conn-1', 1);

          expect(result.isError(), isTrue);
          expect(result.exceptionOrNull(), isA<UnsupportedFeatureError>());
        },
      );

      test(
        'should_propagate_async_worker_pool_stats_failure_from_repository',
        () async {
          await service.initialize();
          final result = await service.getAsyncWorkerPoolStats();

          expect(result.isError(), isTrue);
          expect(result.exceptionOrNull(), isA<UnsupportedFeatureError>());
        },
      );
    });

    group('delegation and streams', () {
      late String connectionId;

      setUp(() async {
        await service.initialize();
        connectionId = (await service.connect('DSN=test')).getOrThrow().id;
      });

      test('should_return_driver_name_when_detectDriver_succeeds', () async {
        final name = await service.detectDriver('DSN=test');
        expect(name, equals('mock'));
      });

      test(
        'should_delegate_executeQueryMultiParams_to_repository',
        () async {
          final result = await service.executeQueryMultiParams(
            connectionId,
            'SELECT 1; SELECT 2',
            [1],
          );

          expect(result.isSuccess(), isTrue);
          expect(mockRepo.executeQueryMultiFullCalled, isTrue);
        },
      );

      test(
        'should_emit_multi_result_items_when_streamQueryMulti_succeeds',
        () async {
          final items = await service
              .streamQueryMulti(connectionId, 'SELECT 1; SELECT 2')
              .toList();

          expect(items, hasLength(2));
          expect(items.every((r) => r.isSuccess()), isTrue);
        },
      );
    });
  });
}
