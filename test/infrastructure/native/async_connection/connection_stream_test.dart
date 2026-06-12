import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection streaming protocol', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerStreamingSupport,
      );
    });

    tearDown(() {
      async.dispose();
    });

    test('streamQueryBatched should parse streamed native payload', () async {
      await async.initialize();
      final chunks =
          await async.streamQueryBatched(1, 'SELECT 1', fetchSize: 10).toList();

      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));
    });

    test('streamQuery should parse streamed native payload', () async {
      await async.initialize();
      final chunks = await async.streamQuery(1, 'SELECT 1').toList();

      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));
    });
  });

  group('AsyncNativeOdbcConnection async stream', () {
    test('streamAsync should poll and parse streamed native payload', () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerAsyncStreamSupport,
      );
      await async.initialize();

      final chunks = await async.streamAsync(1, 'SELECT 1').toList();
      expect(chunks.length, equals(1));
      expect(chunks.first.rowCount, equals(1));
      expect(chunks.first.columnCount, equals(1));
      expect(chunks.first.columns.first.name, equals('id'));
      expect(chunks.first.rows.first.first, equals(1));

      async.dispose();
    });
  });

  group('AsyncNativeOdbcConnection streaming failures', () {
    test('streamQuery should throw AsyncError when stream start fails',
        () async {
      final async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerStreamStartFailure,
      );
      await async.initialize();

      await expectLater(
        () => async.streamQuery(1, 'SELECT 1').toList(),
        throwsA(
          isA<AsyncError>()
              .having((e) => e.code, 'code', AsyncErrorCode.queryFailed)
              .having(
                (e) => e.message,
                'message',
                contains('stream start failed'),
              ),
        ),
      );
      async.dispose();
    });

    test(
      'streamQuery should close failed stream before next start attempt',
      () async {
        final async = AsyncNativeOdbcConnection(
          isolateEntry: fakeWorkerFetchFailureRequiresClose,
        );
        await async.initialize();

        Future<void> runAndExpectFetchFailure() async {
          await expectLater(
            () => async.streamQuery(1, 'SELECT 1').toList(),
            throwsA(
              isA<AsyncError>()
                  .having((e) => e.code, 'code', AsyncErrorCode.queryFailed)
                  .having(
                    (e) => e.message,
                    'message',
                    contains('fetch failed'),
                  ),
            ),
          );
        }

        await runAndExpectFetchFailure();
        await runAndExpectFetchFailure();
        async.dispose();
      },
    );
  });
}
