import 'dart:typed_data';

import 'package:odbc_fast/application/repositories/odbc_repository_extensions.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';
import 'helpers.dart';

void main() {
  group('OdbcRepositoryImpl wave 7b guards and error mapping', () {
    late FakeAsyncNativeForRepositoryErrors native;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      native = FakeAsyncNativeForRepositoryErrors();
      addTearDown(native.dispose);
      repository = OdbcRepositoryImpl(native);
      await repository.initialize();
      final conn = (await repository.connect('Driver={Test}')).getOrNull();
      expect(conn, isNotNull);
      connectionId = conn!.id;
    });

    test(
      'connect maps structured error when native connect returns zero',
      () async {
        native
          ..connectReturnsZero = true
          ..globalStructuredError = const StructuredError(
            sqlState: sqlState0A000,
            nativeCode: 18456,
            message: 'Login failed for user',
          );
        final result = await repository.connect('Driver={Test}');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ConnectionError>());
            final err = e as ConnectionError;
            expect(err.message, 'Login failed for user');
            expect(err.sqlState, '0A000');
            expect(err.nativeCode, 18456);
          },
        );
      },
    );

    test(
      'disconnect maps connection-scoped structured error on native failure',
      () async {
        native
          ..disconnectSuccess = false
          ..connectionStructuredError = const StructuredError(
            sqlState: [52, 50, 48, 48, 48],
            nativeCode: 1,
            message: 'Connection is busy',
          );
        final result = await repository.disconnect(connectionId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ConnectionError>());
            final err = e as ConnectionError;
            expect(err.message, 'Connection is busy');
            expect(err.sqlState, '42000');
          },
        );
      },
    );

    test(
      'prepare maps structured error when native returns zero statement id',
      () async {
        native
          ..prepareResult = 0
          ..globalStructuredError = const StructuredError(
            sqlState: [52, 50, 48, 48, 48],
            nativeCode: 8180,
            message: 'Statement preparation failed',
          );
        final result = await repository.prepare(connectionId, 'SELECT 1');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            final err = e as QueryError;
            expect(err.message, 'Statement preparation failed');
            expect(err.sqlState, '42000');
            expect(err.nativeCode, 8180);
          },
        );
      },
    );

    test(
      'beginTransaction maps structured error when native returns zero txn id',
      () async {
        native.globalStructuredError = const StructuredError(
          sqlState: [50, 56, 48, 48, 48],
          nativeCode: 3902,
          message: 'Transaction already active',
        );
        final result = await repository.beginTransaction(
          connectionId,
          IsolationLevel.readCommitted,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            final err = e as QueryError;
            expect(err.message, 'Transaction already active');
            expect(err.sqlState, '28000');
          },
        );
      },
    );

    test(
      'executePrepared maps structured error when native returns null buffer',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..executePreparedResult = null
          ..globalStructuredError = const StructuredError(
            sqlState: [52, 50, 48, 48, 48],
            nativeCode: 102,
            message: 'Execute failed',
          );
        final result = await repository.executePreparedParamValuesFromObjects(
          connectionId,
          stmtId,
          [],
          null,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            final err = e as QueryError;
            expect(err.message, 'Execute failed');
            expect(err.nativeCode, 102);
          },
        );
      },
    );
    test(
      'cancelStatement maps unsupported cancellation structured error',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..cancelStatementSuccess = false
          ..globalStructuredError = const StructuredError(
            sqlState: sqlState0A000,
            nativeCode: 5001,
            message: 'Unsupported feature: statement cancellation',
          );
        final result = await repository.cancelStatement(connectionId, stmtId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<UnsupportedFeatureError>());
            final err = e as UnsupportedFeatureError;
            expect(err.sqlState, '0A000');
            expect(err.nativeCode, 5001);
            expect(
              err.message,
              contains(odbcCancelStatementPreferQueryTimeoutHint),
            );
          },
        );
      },
    );

    test(
      'cancelStatement maps invalid statement id text to ValidationError',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..cancelStatementSuccess = false
          ..globalStructuredError = null
          ..errorMessage = 'Invalid statement ID 999';
        final result = await repository.cancelStatement(connectionId, stmtId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              'Invalid statement ID 999',
            );
          },
        );
      },
    );
    test(
      'executeQueryNamed maps missing named parameters to ValidationError',
      () async {
        final result = await repository.executeQueryNamed(
          connectionId,
          'SELECT :id',
          <String, Object?>{},
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('Missing required parameters'),
            );
          },
        );
      },
    );

    test(
      'executeQueryMultiFull maps malformed multi buffer to QueryError',
      () async {
        native.executeQueryMultiResult = malformedMultiResultBuffer();
        final result = await repository.executeQueryMultiFull(
          connectionId,
          'SELECT 1',
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );
    group('statement lifecycle via fake', () {
      late FakeRepoNative localNative;
      late OdbcRepositoryImpl localRepo;
      late String connId;
      late int stmtId;

      setUp(() async {
        localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        connId = (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
        stmtId = (await localRepo.prepare(connId, 'SELECT 1')).getOrNull()!;
      });

      test(
        'closeStatement should_succeed_and_clear_statement_metadata',
        () async {
          final r = await localRepo.closeStatement(connId, stmtId);
          expect(r.isSuccess(), isTrue);

          // Following call must now see the statement as unknown.
          final after = await localRepo.closeStatement(connId, stmtId);
          expect(after.isError(), isTrue);
          after.fold(
            (_) => fail('Expected ValidationError'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_clear_metadata_even_when_native_fails',
        () async {
          localNative
            ..closeStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 42,
              message: 'native close refused',
            );

          final r = await localRepo.closeStatement(connId, stmtId);
          expect(r.isError(), isTrue);

          // Even on failure, the Dart-side metadata must be wiped.
          final after = await localRepo.closeStatement(connId, stmtId);
          after.fold(
            (_) => fail('Expected ValidationError after wipe'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_reject_unknown_statement_id',
        () async {
          final r = await localRepo.closeStatement(connId, 999_999);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_reject_statement_owned_by_other_connection',
        () async {
          final otherConn =
              (await localRepo.connect('Driver={Other}')).getOrNull()!.id;
          final r = await localRepo.closeStatement(otherConn, stmtId);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              contains('does not belong'),
            ),
          );
        },
      );

      test(
        'cancelStatement should_succeed_when_native_returns_true',
        () async {
          localNative.cancelStatementSuccess = true;
          final r = await localRepo.cancelStatement(connId, stmtId);
          expect(r.isSuccess(), isTrue);
        },
      );

      test(
        'cancelStatement should_translate_unsupported_sqlstate_0A000',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [48, 65, 48, 48, 48],
              nativeCode: 5001,
              message: 'cancellation not supported',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected UnsupportedFeatureError'),
            (e) {
              expect(e, isA<UnsupportedFeatureError>());
              expect(
                (e as UnsupportedFeatureError).sqlState,
                equals('0A000'),
              );
            },
          );
        },
      );

      test(
        'cancelStatement should_translate_unsupported_native_code_5001',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 5001,
              message: 'engine does not implement cancellation',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected UnsupportedFeatureError'),
            (e) => expect(e, isA<UnsupportedFeatureError>()),
          );
        },
      );

      test(
        'cancelStatement should_surface_query_error_for_unrelated_failure',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..errorMessage = 'driver is busy'
            ..globalStructuredError = const StructuredError(
              sqlState: [50, 53, 48, 48, 48],
              nativeCode: 99,
              message: '',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected QueryError'),
            (e) {
              expect(e, isA<QueryError>());
              final err = e as QueryError;
              expect(err.message, equals('driver is busy'));
            },
          );
        },
      );

      test(
        'cancelStatement should_reject_unknown_statement_id',
        () async {
          final r = await localRepo.cancelStatement(connId, 9_999_999);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(e, isA<ValidationError>()),
          );
        },
      );
    });
    group('slow query detection', () {
      test(
        'should_emit_SlowQueryDetected_when_threshold_is_zero_duration',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          // Threshold of Duration.zero means any non-zero elapsed time
          // crosses it — deterministic across CI runs.
          final conn = (await localRepo.connect(
            'Driver={Test}',
            options: const ConnectionOptions(
              slowQueryThreshold: Duration.zero,
            ),
          ))
              .getOrNull()!;

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          // executeQueryMultiFull threads `sqlForSlowQueryDetection` through
          // `_withReconnect`, exercising the slow-query hook with the fake.
          localNative.executeQueryMultiResult = Uint8List(0);
          final result = await localRepo.executeQueryMultiFull(
            conn.id,
            'SELECT 1',
          );
          expect(result.isSuccess(), isTrue);

          final slow = events.whereType<SlowQueryDetected>().toList();
          expect(slow, hasLength(1));
          expect(slow.single.connectionId, equals(conn.id));
          expect(slow.single.sql, equals('SELECT 1'));
        },
      );

      test(
        'should_not_emit_SlowQueryDetected_when_threshold_is_unset',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final conn = (await localRepo.connect('Driver={Test}')).getOrNull()!;

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          localNative.executeQueryMultiResult = Uint8List(0);
          await localRepo.executeQueryMultiFull(conn.id, 'SELECT 1');

          expect(events.whereType<SlowQueryDetected>(), isEmpty);
        },
      );
    });
  });
}
