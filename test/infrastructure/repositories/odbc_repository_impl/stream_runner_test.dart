import 'dart:typed_data';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
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
      'streamQueryMulti yields QueryError when stream fetch fails',
      () async {
        native
          ..streamMultiStartBatchedResult = 9
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: false,
              error: 'stream fetch blew up',
            ),
          ];
        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(1));
        chunks.single.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            expect((e as QueryError).message, 'stream fetch blew up');
          },
        );
      },
    );

    test(
      'streamQueryMulti yields MalformedPayloadError on leftover stream bytes',
      () async {
        native
          ..streamMultiStartBatchedResult = 10
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: Uint8List.fromList([multiStreamItemTagResultSet]),
            ),
          ];
        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(1));
        chunks.single.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<MalformedPayloadError>()),
        );
      },
    );

    test(
      'streamQueryMulti yields QueryError when stream start fails and '
      'multi-result parse fails',
      () async {
        native
          ..streamMultiStartBatchedResult = 0
          ..executeQueryMultiResult = malformedMultiResultBuffer();
        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(1));
        chunks.single.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            expect(
              (e as QueryError).message,
              contains('Failed to start streaming multi-result'),
            );
          },
        );
      },
    );

    test(
      'streamQueryMulti decodes row-count frame split across stream fetches',
      () async {
        final frame = rowCountMultiStreamFrame(4242);
        const mid = 5;
        native
          ..streamMultiStartBatchedResult = 9001
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: Uint8List.sublistView(frame, 0, mid),
              hasMore: true,
            ),
            StreamFetchResponse(
              0,
              success: true,
              data: Uint8List.sublistView(frame, mid),
            ),
          ];

        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(1));
        expect(chunks.single.isSuccess(), isTrue);
        final item = chunks.single.getOrNull()!;
        expect(item.isRowCount, isTrue);
        expect(item.rowCount, equals(4242));
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

    group('streamQueryNamed', () {
      test(
        'should_yield_validation_failure_when_named_param_is_missing',
        () async {
          final chunks = await repository.streamQueryNamed(
            connectionId,
            'SELECT :x FROM t',
            <String, Object?>{},
          ).toList();

          expect(chunks, hasLength(1));
          final item = chunks.first;
          expect(item.isError(), isTrue);
          item.fold(
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
        'should_yield_failure_when_connectionId_is_invalid',
        () async {
          final chunks = await repository.streamQueryNamed(
            'nonexistent-connection',
            'SELECT :x FROM t',
            {'x': 1},
          ).toList();

          expect(chunks, hasLength(1));
          expect(chunks.first.isError(), isTrue);
        },
      );

      test(
        'should_yield_exactly_one_chunk',
        () async {
          // Even on connection-not-found failure, exactly one item is emitted.
          final count = await repository.streamQueryNamed(
            'bad-conn',
            'SELECT :a, :b FROM t',
            {'a': 1, 'b': 2},
          ).length;

          expect(count, equals(1));
        },
      );
    });
  });
}
