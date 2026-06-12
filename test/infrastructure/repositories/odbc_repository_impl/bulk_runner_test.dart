import 'dart:typed_data';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';

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
      'bulkInsert maps structured error when native returns negative rows',
      () async {
        native
          ..bulkInsertResult = -1
          ..globalStructuredError = const StructuredError(
            sqlState: [52, 50, 48, 48, 48],
            nativeCode: 547,
            message: 'Bulk insert constraint violation',
          );
        final result = await repository.bulkInsert(
          connectionId,
          't',
          ['c'],
          Uint8List(0),
          0,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            expect(
              (e as QueryError).message,
              'Bulk insert constraint violation',
            );
          },
        );
      },
    );
  });
}
