import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/async_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

class _FakeAsyncNativeForStreaming extends AsyncNativeOdbcConnection {
  _FakeAsyncNativeForStreaming() : super(requestTimeout: Duration.zero);

  Stream<ParsedRowBuffer> Function()? batchedStreamFactory;
  Stream<ParsedRowBuffer> Function()? fallbackStreamFactory;
  StructuredError? structuredError;
  String errorMessage = '';
  int batchedCalls = 0;
  int fallbackCalls = 0;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async => 99;

  @override
  Future<bool> disconnect(int connectionId) async => true;

  @override
  Future<StructuredError?> getStructuredError() async => structuredError;

  @override
  Future<String> getError() async => errorMessage;

  @override
  Stream<ParsedRowBuffer> streamQueryBatched(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
    int? maxBufferBytes,
  }) {
    batchedCalls++;
    final factory = batchedStreamFactory;
    if (factory == null) {
      return const Stream.empty();
    }
    return factory();
  }

  @override
  Stream<ParsedRowBuffer> streamQuery(
    int connectionId,
    String sql, {
    int chunkSize = 1000,
    int? maxBufferBytes,
  }) {
    fallbackCalls++;
    final factory = fallbackStreamFactory;
    if (factory == null) {
      return const Stream.empty();
    }
    return factory();
  }

  @override
  void dispose() {}
}

ParsedRowBuffer _chunk(int value) {
  return ParsedRowBuffer(
    columns: const [ColumnMetadata(name: 'id', odbcType: 2)],
    rows: [
      [value],
    ],
    rowCount: 1,
    columnCount: 1,
  );
}

void main() {
  group('OdbcRepositoryImpl streaming fallback and errors', () {
    late _FakeAsyncNativeForStreaming asyncNative;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      asyncNative = _FakeAsyncNativeForStreaming();
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
      final connResult = await repository.connect('DSN=Fake');
      final connection = connResult.getOrNull();
      expect(connection, isNotNull);
      connectionId = connection!.id;
    });

    tearDown(() {
      asyncNative.dispose();
    });

    test('falls back to classic stream when batched fails before first chunk',
        () async {
      asyncNative
        ..batchedStreamFactory = () async* {
          await Future<void>.delayed(Duration.zero);
          throw Exception('fetch failed before first chunk');
        }
        ..fallbackStreamFactory = () async* {
          yield _chunk(1);
          yield _chunk(2);
        };

      final chunks =
          await repository.streamQuery(connectionId, 'SELECT 1').toList();
      expect(asyncNative.batchedCalls, equals(1));
      expect(asyncNative.fallbackCalls, equals(1));
      expect(chunks.length, equals(2));
      expect(chunks.every((c) => c.isSuccess()), isTrue);
    });

    test('classifies protocol error during mid-stream consumption', () async {
      asyncNative.batchedStreamFactory = () async* {
        yield _chunk(1);
        throw const FormatException('leftover bytes in protocol');
      };

      final chunks =
          await repository.streamQuery(connectionId, 'SELECT 1').toList();
      expect(asyncNative.batchedCalls, equals(1));
      expect(asyncNative.fallbackCalls, equals(0));
      expect(chunks.length, equals(2));
      expect(chunks.first.isSuccess(), isTrue);
      expect(chunks.last.isError(), isTrue);
      chunks.last.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect(
            (e as QueryError).message,
            contains('Streaming protocol error'),
          );
        },
      );
    });

    test('returns timeout failure for streaming query timeout', () async {
      final connResult = await repository.connect(
        'DSN=Fake',
        options:
            const ConnectionOptions(queryTimeout: Duration(milliseconds: 30)),
      );
      connectionId = connResult.getOrNull()!.id;

      asyncNative.batchedStreamFactory = () async* {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        yield _chunk(1);
      };

      final chunks =
          await repository.streamQuery(connectionId, 'SELECT 1').toList();
      expect(chunks.length, equals(1));
      expect(chunks.single.isError(), isTrue);
      chunks.single.fold(
        (_) => fail('Expected timeout failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, equals('Query timed out'));
        },
      );
    });

    test('classifies worker termination during streaming as interruption',
        () async {
      asyncNative.batchedStreamFactory = () async* {
        yield _chunk(1);
        throw const AsyncError(
          code: AsyncErrorCode.workerTerminated,
          message: 'Worker isolate terminated',
        );
      };

      final chunks =
          await repository.streamQuery(connectionId, 'SELECT 1').toList();
      expect(chunks.length, equals(2));
      expect(chunks.first.isSuccess(), isTrue);
      expect(chunks.last.isError(), isTrue);
      chunks.last.fold(
        (_) => fail('Expected interruption failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Streaming interrupted'));
        },
      );
    });

    test('classifies SQL error with structured info when stream fails',
        () async {
      asyncNative
        ..structuredError = const StructuredError(
          sqlState: [52, 50, 48, 48, 48], // "42000"
          nativeCode: 156,
          message: 'Incorrect syntax near SELECT',
        )
        ..batchedStreamFactory = () async* {
          throw Exception('batched failed');
        }
        ..fallbackStreamFactory = () async* {
          throw Exception('fallback failed');
        };

      final chunks =
          await repository.streamQuery(connectionId, 'SELECT 1').toList();
      expect(chunks.length, equals(1));
      expect(chunks.single.isError(), isTrue);
      chunks.single.fold(
        (_) => fail('Expected SQL failure'),
        (e) {
          expect(e, isA<QueryError>());
          final err = e as QueryError;
          expect(err.message, contains('Streaming SQL error'));
          expect(err.sqlState, equals('42000'));
          expect(err.nativeCode, equals(156));
        },
      );
    });
  });
}
