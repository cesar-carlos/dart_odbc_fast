import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

import '../../../helpers/binary_protocol_test_helper.dart';
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
      'streamQueryMulti passes default result encoding to native multi-start',
      () async {
        native
          ..streamMultiStartBatchedResult = 42
          ..streamFetchResponses = [
            StreamFetchResponse(0, success: true),
          ];
        await repository.streamQueryMulti(connectionId, 'SELECT 1').toList();
        expect(native.lastStreamMultiStartResultEncodingWire, equals(0));
      },
    );

    test(
      'streamQueryMulti forces row-major even when default encoding is '
      'columnar',
      () async {
        final columnarRepo = OdbcRepositoryImpl(
          native,
          defaultResultEncoding: ResultEncoding.columnar,
        );
        await columnarRepo.initialize();
        final colConn =
            (await columnarRepo.connect('Driver={Test}')).getOrNull()!;
        native
          ..streamMultiStartBatchedResult = 43
          ..streamFetchResponses = [
            StreamFetchResponse(0, success: true),
          ];
        await columnarRepo.streamQueryMulti(colConn.id, 'SELECT 1').toList();
        expect(native.lastStreamMultiStartResultEncodingWire, equals(0));
      },
    );

    test(
      'streamQueryMulti forces row-major even when default is '
      'columnarCompressed',
      () async {
        final compressedRepo = OdbcRepositoryImpl(
          native,
          defaultResultEncoding: ResultEncoding.columnarCompressed,
        );
        await compressedRepo.initialize();
        final compressedConn =
            (await compressedRepo.connect('Driver={Test}')).getOrNull()!;
        native
          ..streamMultiStartBatchedResult = 44
          ..streamFetchResponses = [
            StreamFetchResponse(0, success: true),
          ];
        await compressedRepo
            .streamQueryMulti(compressedConn.id, 'SELECT 1')
            .toList();
        expect(native.lastStreamMultiStartResultEncodingWire, equals(0));
      },
    );

    test(
      'streamQueryMulti coalesces tag0+tag2 into one result-set item',
      () async {
        final frames = BytesBuilder()
          ..add(
            resultSetMultiStreamFrame(
              ['id'],
              [
                ['1'],
              ],
            ),
          )
          ..add(
            resultSetMultiStreamFrame(
              ['id'],
              [
                ['2'],
              ],
              tag: multiStreamItemTagResultSetBatch,
            ),
          )
          ..add(rowCountMultiStreamFrame(99));
        native
          ..streamMultiStartBatchedResult = 55
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: frames.toBytes(),
            ),
          ];

        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(2));
        expect(native.lastStreamMultiStartWasAsync, isTrue);
        expect(chunks[0].isSuccess(), isTrue);
        final first = chunks[0].getOrNull()!;
        expect(first.isResultSet, isTrue);
        expect(first.resultSet!.rowCount, equals(2));
        expect(first.resultSet!.rows, hasLength(2));
        expect(chunks[1].isSuccess(), isTrue);
        expect(chunks[1].getOrNull()!.rowCount, equals(99));
      },
    );

    test(
      'streamQueryMulti does not merge consecutive tag0 result sets',
      () async {
        final frames = BytesBuilder()
          ..add(
            resultSetMultiStreamFrame(
              ['a'],
              [
                ['1'],
              ],
            ),
          )
          ..add(
            resultSetMultiStreamFrame(
              ['b'],
              [
                ['2'],
              ],
            ),
          );
        native
          ..streamMultiStartBatchedResult = 56
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: frames.toBytes(),
            ),
          ];

        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1; SELECT 2')
            .toList();
        expect(chunks, hasLength(2));
        expect(chunks[0].getOrNull()!.resultSet!.columns, equals(['a']));
        expect(chunks[1].getOrNull()!.resultSet!.columns, equals(['b']));
      },
    );

    test(
      'streamQueryMulti coalesces multiple tag2 continuations into one set',
      () async {
        final frames = BytesBuilder()
          ..add(
            resultSetMultiStreamFrame(
              ['id'],
              [
                ['1'],
              ],
            ),
          )
          ..add(
            resultSetMultiStreamFrame(
              ['id'],
              [
                ['2'],
              ],
              tag: multiStreamItemTagResultSetBatch,
            ),
          )
          ..add(
            resultSetMultiStreamFrame(
              ['id'],
              [
                ['3'],
                ['4'],
              ],
              tag: multiStreamItemTagResultSetBatch,
            ),
          )
          ..add(rowCountMultiStreamFrame(7));
        native
          ..streamMultiStartBatchedResult = 57
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: frames.toBytes(),
            ),
          ];

        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();
        expect(chunks, hasLength(2));
        final first = chunks[0].getOrNull()!;
        expect(first.isResultSet, isTrue);
        expect(first.resultSet!.rowCount, equals(4));
        expect(first.resultSet!.rows, hasLength(4));
        expect(
          first.resultSet!.rows.map((r) => r[0]).toList(),
          equals(['1', '2', '3', '4']),
        );
        expect(chunks[1].getOrNull()!.rowCount, equals(7));
      },
    );

    test(
      'streamQueryMulti forwards fetchSize and seeds streamFetch bufferSize',
      () async {
        native
          ..streamMultiStartBatchedResult = 58
          ..streamFetchResponses = [
            StreamFetchResponse(0, success: true),
          ];

        const fetchSize = 2500;
        const chunkSize = 256 * 1024;
        await repository
            .streamQueryMulti(
              connectionId,
              'SELECT 1',
              fetchSize: fetchSize,
              chunkSize: chunkSize,
            )
            .toList();

        expect(native.lastStreamMultiStartFetchSize, equals(fetchSize));
        expect(native.lastStreamMultiStartChunkSize, equals(chunkSize));
        expect(native.lastStreamFetchBufferSize, equals(chunkSize));
      },
    );

    test(
      'streamQueryMulti async ready path uses one pollAndFetch hop',
      () async {
        final frame = rowCountMultiStreamFrame(42);
        native
          ..streamMultiStartBatchedResult = 59
          ..streamFetchResponses = [
            StreamFetchResponse(
              0,
              success: true,
              data: frame,
            ),
          ];

        final chunks = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();

        expect(chunks, hasLength(1));
        expect(chunks.single.getOrNull()!.rowCount, equals(42));
        // One combined hop for the ready fetch + one for the Done poll.
        expect(native.streamPollAndFetchCallCount, equals(2));
        expect(native.lastStreamFetchBufferSize, equals(64 * 1024));
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

      test(
        'should_stream_batched_chunks_with_named_params_buffer',
        () async {
          final frameA = createBinaryProtocolBuffer(
            columns: const [(name: 'n', type: 2)],
            rows: const [
              [1],
            ],
          );
          final frameB = createBinaryProtocolBuffer(
            columns: const [(name: 'n', type: 2)],
            rows: const [
              [2],
            ],
          );
          native
            ..streamStartBatchedResult = 42
            ..streamFetchResponses = [
              StreamFetchResponse(
                0,
                success: true,
                data: frameA,
                hasMore: true,
              ),
              StreamFetchResponse(
                0,
                success: true,
                data: frameB,
              ),
            ];

          final chunks = await repository.streamQueryNamed(
            connectionId,
            'SELECT :id FROM t WHERE x = :id',
            {'id': 7},
          ).toList();

          expect(chunks, hasLength(2));
          expect(chunks.every((c) => c.isSuccess()), isTrue);
          expect(
            native.lastStreamStartSql,
            equals('SELECT ? FROM t WHERE x = ?'),
          );
          expect(native.lastStreamStartParamsBuffer, isNotNull);
          expect(native.lastStreamStartParamsBuffer!.isNotEmpty, isTrue);
        },
      );
    });
  });
}
