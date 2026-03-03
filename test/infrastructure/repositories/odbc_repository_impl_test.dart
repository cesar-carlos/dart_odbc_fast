/// Unit tests for [OdbcRepositoryImpl].
///
/// Timeout and auto-reconnect behavior require a backend that delays or
/// returns connectionLost; see E2E or integration tests when ODBC is available.
library;

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcRepositoryImpl', () {
    late AsyncNativeOdbcConnection asyncNative;
    late OdbcRepositoryImpl repository;

    setUp(() async {
      asyncNative = AsyncNativeOdbcConnection();
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
    });

    tearDown(() {
      asyncNative.dispose();
    });

    test('executeQuery returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.executeQuery('invalid-id', 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('streamQuery emits ValidationError when connectionId invalid',
        () async {
      final chunks =
          await repository.streamQuery('invalid-id', 'SELECT 1').toList();
      expect(chunks.length, 1);
      final first = chunks.first;
      expect(first.isSuccess(), isFalse);
      first.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('executeQueryParams returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.executeQueryParams(
        'invalid-id',
        'SELECT 1',
        [],
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('executeQueryMulti returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.executeQueryMulti(
        'invalid-id',
        'SELECT 1',
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test(
        'executeQueryMultiFull returns ValidationError '
        'when connectionId invalid', () async {
      final result = await repository.executeQueryMultiFull(
        'invalid-id',
        'SELECT 1',
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('connect with empty string returns ValidationError', () async {
      final result = await repository.connect('');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Connection string cannot be empty',
          );
        },
      );
    });

    test(
        'connect with invalid options returns ValidationError '
        'before native call', () async {
      final result = await repository.connect(
        'DSN=Fake',
        options: const ConnectionOptions(
          queryTimeout: Duration(seconds: -1),
        ),
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'queryTimeout cannot be negative',
          );
        },
      );
    });

    test('poolCreate with maxSize <= 0 returns ValidationError', () async {
      final result = await repository.poolCreate('DSN=Fake', 0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Pool maxSize must be greater than zero',
          );
        },
      );
    });

    test('metadataCacheEnable validates maxEntries and ttlSeconds', () async {
      final result = await repository.metadataCacheEnable(
        maxEntries: 0,
        ttlSeconds: 0,
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'maxEntries and ttlSeconds must be greater than zero',
          );
        },
      );
    });

    test('cancelStream validates invalid streamId', () async {
      final result = await repository.cancelStream(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, 'Invalid stream ID');
        },
      );
    });

    test('validateConnectionString validates empty connection string',
        () async {
      final result = await repository.validateConnectionString('');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Connection string cannot be empty',
          );
        },
      );
    });

    test('getDriverCapabilities validates empty connection string', () async {
      final result = await repository.getDriverCapabilities('');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Connection string cannot be empty',
          );
        },
      );
    });

    test('executeAsyncStart validates invalid connectionId', () async {
      final result =
          await repository.executeAsyncStart('invalid-id', 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('asyncPoll validates invalid requestId', () async {
      final result = await repository.asyncPoll(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid async request ID',
          );
        },
      );
    });

    test('asyncGetResult validates invalid requestId', () async {
      final result = await repository.asyncGetResult(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid async request ID',
          );
        },
      );
    });

    test('asyncCancel validates invalid requestId', () async {
      final result = await repository.asyncCancel(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid async request ID',
          );
        },
      );
    });

    test('asyncFree validates invalid requestId', () async {
      final result = await repository.asyncFree(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid async request ID',
          );
        },
      );
    });

    test('streamStartAsync validates invalid connectionId', () async {
      final result =
          await repository.streamStartAsync('invalid-id', 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid connection ID',
          );
        },
      );
    });

    test('streamPollAsync validates invalid streamId', () async {
      final result = await repository.streamPollAsync(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'Invalid stream ID',
          );
        },
      );
    });
  });
}
