import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection named parameters', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(isolateEntry: fakeWorkerNamedSupport);
    });

    tearDown(() {
      async.dispose();
    });

    test('should prepare and execute named prepared statement', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id',
        timeoutMs: 250,
      );
      expect(stmtId, equals(42));

      final result = await async.executePreparedNamed(
        stmtId,
        {'id': 1},
        100,
        500,
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('should execute query with named parameters', () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT * FROM users WHERE id = @id',
        {'id': 7},
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(1));
    });

    test('should preserve repeated named placeholders for query execution',
        () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT * FROM users WHERE id = @id OR parent_id = @id',
        {'id': 7},
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(2));
    });

    test('should support more than five named parameters', () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT @a, @b, @c, @d, @e, @f',
        {
          'a': 1,
          'b': 2,
          'c': 3,
          'd': 4,
          'e': 5,
          'f': 6,
        },
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
      expect(result!.single, equals(6));
    });

    test('should throw invalidParameter when named param is missing', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id AND name = :name',
      );
      expect(stmtId, equals(42));

      try {
        await async.executePreparedNamed(stmtId, {'id': 1}, 0, 1000);
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.invalidParameter));
        expect(e.message, contains('Missing required parameters'));
      }
    });

    test('should clear named prepared metadata after clearAllStatements',
        () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id',
      );
      expect(stmtId, equals(42));

      final clearCode = await async.clearAllStatements();
      expect(clearCode, equals(0));

      await expectLater(
        () => async.executePreparedNamed(stmtId, {'id': 1}, 0, 1000),
        throwsA(
          isA<AsyncError>().having(
            (error) => error.message,
            'message',
            contains('prepareNamed'),
          ),
        ),
      );
    });
  });
}
