import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection timeout', () {
    test(
      'should throw AsyncError with requestTimeout when worker '
      'does not respond',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(milliseconds: 50),
          isolateEntry: fakeWorkerNoResponse,
        );
        await async.initialize();

        expect(
          () => async.connect('DSN=Test'),
          throwsA(isA<AsyncError>()),
        );

        try {
          await async.connect('DSN=Test');
          fail('Should have thrown AsyncError');
        } on AsyncError catch (e) {
          expect(e.code, equals(AsyncErrorCode.requestTimeout));
          expect(e.message, contains('did not respond'));
        } finally {
          async.dispose();
        }
      },
    );

    test('should allow Duration.zero to disable timeout', () async {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: Duration.zero,
        isolateEntry: fakeWorkerNoResponse,
      );
      await async.initialize();

      final connectFuture = async.connect('DSN=Test');
      async.dispose();

      expect(
        () => connectFuture,
        throwsA(isA<AsyncError>()),
      );
      try {
        await connectFuture;
        fail('Should have thrown');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.workerTerminated));
      }
    });
  });

  group('AsyncNativeOdbcConnection dispose with pending', () {
    test(
      'should complete pending requests with error when dispose is called',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(seconds: 60),
          isolateEntry: fakeWorkerNoResponse,
        );
        await async.initialize();

        final connectFuture = async.connect('DSN=Test');
        async.dispose();

        expect(
          () => connectFuture,
          throwsA(isA<AsyncError>()),
        );
        try {
          await connectFuture;
          fail('Should have thrown AsyncError');
        } on AsyncError catch (e) {
          expect(e.code, equals(AsyncErrorCode.workerTerminated));
          expect(e.message, contains('Connection disposed'));
        }
      },
    );
  });
}
