
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('OdbcRepositoryImpl fake native error mapping', () {
    test(
      'initialize returns EnvironmentNotInitializedError when native false',
      () async {
        final native = FakeRepoNative()..initializeSuccess = false;
        addTearDown(native.dispose);
        final repo = OdbcRepositoryImpl(native);
        final result = await repo.initialize();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<EnvironmentNotInitializedError>()),
        );
      },
    );

    test(
      'validateConnectionString maps native rejection to ValidationError',
      () async {
        final native = FakeRepoNative();
        addTearDown(native.dispose);
        final repo = OdbcRepositoryImpl(native);
        await repo.initialize();
        final result = await repo.validateConnectionString('Driver={Test};');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect((e as ValidationError).message, 'rejected by fake');
          },
        );
      },
    );

    test(
      'disconnect returns ConnectionError when native disconnect fails',
      () async {
        final native = FakeRepoNative()..disconnectSuccess = false;
        addTearDown(native.dispose);
        final repo = OdbcRepositoryImpl(native);
        await repo.initialize();
        final conn = (await repo.connect('Driver={Test}')).getOrNull();
        expect(conn, isNotNull);
        final result = await repo.disconnect(conn!.id);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );
  });
}
