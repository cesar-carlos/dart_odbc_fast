import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
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
    group('transaction primitives via fake', () {
      late FakeRepoNative localNative;
      late OdbcRepositoryImpl localRepo;
      late String connId;

      setUp(() async {
        localNative = FakeRepoNative();
        addTearDown(localNative.dispose);
        localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        connId = (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
      });

      test(
        'commitTransaction should_reject_zero_or_negative_txnId',
        () async {
          final zero = await localRepo.commitTransaction(connId, 0);
          final neg = await localRepo.commitTransaction(connId, -1);
          for (final r in [zero, neg]) {
            expect(r.isError(), isTrue);
            r.fold(
              (_) => fail('Expected ValidationError'),
              (e) => expect(
                (e as ValidationError).message,
                equals('Invalid transaction ID'),
              ),
            );
          }
        },
      );

      test(
        'commitTransaction should_forward_to_native_on_valid_txnId',
        () async {
          localNative.commitTransactionSuccess = true;
          final r = await localRepo.commitTransaction(connId, 12);
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(12));
        },
      );

      test(
        'commitTransaction should_surface_native_failure_as_QueryError',
        () async {
          localNative
            ..commitTransactionSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 9999,
              message: 'commit failed at server',
            );
          final r = await localRepo.commitTransaction(connId, 12);
          expect(r.isError(), isTrue);
          r.fold(
            (_) => fail('Expected failure'),
            (e) {
              expect(e, isA<QueryError>());
              final err = e as QueryError;
              expect(err.message, equals('commit failed at server'));
              expect(err.sqlState, equals('42000'));
              expect(err.nativeCode, equals(9999));
            },
          );
        },
      );

      test(
        'rollbackTransaction should_forward_to_native_on_valid_txnId',
        () async {
          localNative.rollbackTransactionSuccess = true;
          final r = await localRepo.rollbackTransaction(connId, 99);
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(99));
        },
      );

      test(
        'rollbackTransaction should_reject_invalid_connection',
        () async {
          final r = await localRepo.rollbackTransaction('missing', 1);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Invalid connection ID'),
            ),
          );
        },
      );

      group('savepoint operations', () {
        test('createSavepoint should_reject_empty_name_after_trim', () async {
          final r = await localRepo.createSavepoint(connId, 1, '   ');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Savepoint name cannot be empty'),
            ),
          );
        });

        test('createSavepoint should_reject_zero_txnId', () async {
          final r = await localRepo.createSavepoint(connId, 0, 'sp1');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Invalid transaction ID'),
            ),
          );
        });

        test('createSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.createSavepoint(connId, 7, 'sp_alpha');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_alpha'));
        });

        test('rollbackToSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.rollbackToSavepoint(connId, 7, 'sp_beta');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_beta'));
        });

        test('rollbackToSavepoint should_reject_empty_name', () async {
          final r = await localRepo.rollbackToSavepoint(connId, 7, '');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Savepoint name cannot be empty'),
            ),
          );
        });

        test('releaseSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.releaseSavepoint(connId, 7, 'sp_gamma');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_gamma'));
        });

        test(
          'releaseSavepoint should_surface_failure_as_QueryError',
          () async {
            localNative
              ..releaseSavepointSuccess = false
              ..globalStructuredError = const StructuredError(
                sqlState: [52, 50, 48, 48, 48],
                nativeCode: 1234,
                message: 'release failed',
              );
            final r = await localRepo.releaseSavepoint(connId, 7, 'sp');
            r.fold(
              (_) => fail('Expected failure'),
              (e) {
                expect(e, isA<QueryError>());
                expect((e as QueryError).message, equals('release failed'));
              },
            );
          },
        );

        test(
          'savepoint methods should_reject_invalid_connection_id',
          () async {
            final c = await localRepo.createSavepoint('missing', 1, 'sp');
            final r = await localRepo.rollbackToSavepoint('missing', 1, 'sp');
            final rl = await localRepo.releaseSavepoint('missing', 1, 'sp');
            for (final res in [c, r, rl]) {
              res.fold(
                (_) => fail('Expected failure'),
                (e) => expect(
                  (e as ValidationError).message,
                  equals('Invalid connection ID'),
                ),
              );
            }
          },
        );
      });
    });
  });
}
