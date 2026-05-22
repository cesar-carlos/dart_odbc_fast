/// Unit tests for [OdbcRepositoryImpl].
///
/// Timeout and auto-reconnect behavior require a backend that delays or
/// returns connectionLost; see E2E or integration tests when ODBC is available.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

/// SQLSTATE `0A000` as raw bytes for structured cancellation errors.
const List<int> _sqlState0A000 = [48, 65, 48, 48, 48];

/// MULT v2 buffer with unsupported version — [MultiResultParser.parse] rejects.
Uint8List _malformedMultiResultBuffer() {
  final header = ByteData(_headerV2Len)
    ..setUint32(0, multiResultMagic, Endian.little)
    ..setUint16(4, 99, Endian.little)
    ..setUint32(8, 0, Endian.little);
  return header.buffer.asUint8List();
}

// magic(4) + version(2) + reserved(2) + count(4)
const int _headerV2Len = 12;

/// Minimal async fake for repository error-mapping tests (no live ODBC).
class _FakeAsyncNativeForRepositoryErrors extends AsyncNativeOdbcConnection {
  _FakeAsyncNativeForRepositoryErrors() : super(requestTimeout: Duration.zero);

  bool initializeSuccess = true;
  bool disconnectSuccess = true;
  bool connectReturnsZero = false;
  bool cancelStatementSuccess = true;
  String? validateConnectionStringResult = 'rejected by fake';
  String errorMessage = 'disconnect failed';

  StructuredError? globalStructuredError;
  StructuredError? connectionStructuredError;

  int prepareResult = 100;
  int beginTransactionResult = 0;
  int bulkInsertResult = 0;
  int streamMultiStartBatchedResult = 0;
  Uint8List? executePreparedResult;
  Uint8List? executeQueryMultiResult;

  List<StreamFetchResponse> streamFetchResponses = const [];

  int _nextNativeConn = 50;
  var _streamFetchCall = 0;

  @override
  Future<bool> initialize() async => initializeSuccess;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (connectReturnsZero) return 0;
    return ++_nextNativeConn;
  }

  @override
  Future<String?> validateConnectionString(String connectionString) async =>
      validateConnectionStringResult;

  @override
  Future<bool> disconnect(int connectionId) async => disconnectSuccess;

  @override
  Future<String> getError() async => errorMessage;

  @override
  Future<StructuredError?> getStructuredError() async => globalStructuredError;

  @override
  Future<StructuredError?> getStructuredErrorForConnection(
    int connectionId,
  ) async =>
      connectionStructuredError;

  @override
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async =>
      beginTransactionResult;

  @override
  Future<int> prepare(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async =>
      prepareResult;

  @override
  Future<Uint8List?> executePrepared(
    int stmtId,
    List<ParamValue>? params,
    int timeoutOverrideMs,
    int fetchSize, {
    int? maxBufferBytes,
  }) async =>
      executePreparedResult;

  @override
  Future<bool> cancelStatement(int stmtId) async => cancelStatementSuccess;

  @override
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async =>
      bulkInsertResult;

  @override
  Future<Uint8List?> executeQueryMulti(
    int connectionId,
    String sql, {
    int? maxBufferBytes,
  }) async =>
      executeQueryMultiResult;

  @override
  Future<int> streamMultiStartBatched(
    int connectionId,
    String sql, {
    int chunkSize = 64 * 1024,
  }) async =>
      streamMultiStartBatchedResult;

  @override
  Future<StreamFetchResponse> streamFetch(int streamId) async {
    final responses = streamFetchResponses;
    if (responses.isEmpty) {
      return StreamFetchResponse(0, success: false, error: 'no fetch queued');
    }
    final index = _streamFetchCall++;
    if (index >= responses.length) {
      return StreamFetchResponse(0, success: false, error: 'fetch exhausted');
    }
    return responses[index];
  }

  @override
  Future<bool> streamClose(int streamId) async => true;

  @override
  void dispose() {}
}

void _expectValidationError<T extends Object>(
  Result<T> result,
  String message,
) {
  expect(result.isSuccess(), isFalse);
  result.fold(
    (_) => fail('Expected failure'),
    (e) {
      expect(e, isA<ValidationError>());
      expect((e as ValidationError).message, message);
    },
  );
}

void _expectInvalidConnectionId<T extends Object>(Result<T> result) {
  _expectValidationError(result, 'Invalid connection ID');
}

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

    test('additional connection APIs validate invalid connectionId', () async {
      final results = [
        await repository.disconnect('invalid-id'),
        await repository.beginTransaction(
          'invalid-id',
          IsolationLevel.readCommitted,
        ),
        await repository.xaStart(
          'invalid-id',
          Xid.fromStrings(gtrid: 'gtrid'),
        ),
        await repository.prepare('invalid-id', 'SELECT 1'),
        await repository.executeQueryParamBuffer(
          'invalid-id',
          'SELECT ?',
          null,
        ),
        await repository.executeQueryMultiParams(
          'invalid-id',
          'SELECT ?',
          [1],
        ),
        await repository.closeStatement('invalid-id', 7),
        await repository.cancelStatement('invalid-id', 7),
      ];

      for (final result in results) {
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect((e as ValidationError).message, 'Invalid connection ID');
          },
        );
      }
    });

    test('catalog methods validate invalid connectionId', () async {
      final results = [
        await repository.catalogTables('invalid-id'),
        await repository.catalogColumns('invalid-id', 'users'),
        await repository.catalogTypeInfo('invalid-id'),
        await repository.catalogPrimaryKeys('invalid-id', 'users'),
        await repository.catalogForeignKeys('invalid-id', 'users'),
        await repository.catalogIndexes('invalid-id', 'users'),
      ];

      for (final result in results) {
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect((e as ValidationError).message, 'Invalid connection ID');
          },
        );
      }
    });

    test('poolSetSize validates pool id and size before native call', () async {
      final invalidPool = await repository.poolSetSize(0, 4);
      final invalidSize = await repository.poolSetSize(1, 0);

      invalidPool.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, 'Invalid pool ID');
        },
      );
      invalidSize.fold(
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

    test('poolReleaseConnection validates invalid connectionId', () async {
      final result = await repository.poolReleaseConnection('invalid-id');

      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, 'Invalid connection ID');
        },
      );
    });

    test('getConnectionDbmsInfo validates invalid connectionId', () async {
      final result = await repository.getConnectionDbmsInfo('invalid-id');

      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, 'Invalid connection ID');
        },
      );
    });

    test('streamQueryMulti emits ValidationError when connectionId invalid',
        () async {
      final chunks =
          await repository.streamQueryMulti('invalid-id', 'SELECT 1').toList();
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

    test('bulkInsert returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.bulkInsert(
        'invalid-id',
        't',
        ['c'],
        [1],
        1,
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

    test('prepareNamed returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.prepareNamed(
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

    test('executeQueryNamed returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.executeQueryNamed(
        'invalid-id',
        'SELECT 1',
        {},
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

    test('executePrepared returns ValidationError when connectionId invalid',
        () async {
      final result = await repository.executePrepared(
        'invalid-id',
        1,
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

    test('connect with whitespace-only string returns ValidationError',
        () async {
      final result = await repository.connect('   ');
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

    test('poolCreate with whitespace-only string returns ValidationError',
        () async {
      final result = await repository.poolCreate(' \t ', 4);
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
        'connect with maxResultBufferBytes zero returns ValidationError '
        'before native call', () async {
      final result = await repository.connect(
        'DSN=Fake',
        options: const ConnectionOptions(maxResultBufferBytes: 0),
      );
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            'maxResultBufferBytes must be greater than zero',
          );
        },
      );
    });

    test('asyncPoll and asyncGetResult validate negative requestId', () async {
      final pollResult = await repository.asyncPoll(-1);
      final getResultResult = await repository.asyncGetResult(-1);

      for (final result in [pollResult, getResultResult]) {
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
      }
    });

    test('poolSetSize validates negative maxSize before native call', () async {
      final result = await repository.poolSetSize(1, -3);
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

    test('validateConnectionString validates whitespace connection string',
        () async {
      final result = await repository.validateConnectionString('   ');
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

    test('getDriverCapabilities validates whitespace connection string',
        () async {
      final result = await repository.getDriverCapabilities('   ');
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

    test('executeQuery rejects empty connection id before native call',
        () async {
      _expectInvalidConnectionId(await repository.executeQuery('', 'SELECT 1'));
    });

    test(
      'executeQueryParams rejects whitespace-only connection id',
      () async {
        _expectInvalidConnectionId(
          await repository.executeQueryParams('  \t  ', 'SELECT 1', []),
        );
      },
    );

    test('prepare rejects unknown numeric connection id', () async {
      _expectInvalidConnectionId(
        await repository.prepare('99999', 'SELECT 1'),
      );
    });

    test('asyncCancel rejects non-positive request id', () async {
      _expectValidationError(
        await repository.asyncCancel(-1),
        'Invalid async request ID',
      );
    });

    test('asyncFree rejects non-positive request id', () async {
      _expectValidationError(
        await repository.asyncFree(0),
        'Invalid async request ID',
      );
    });

    test('streamPollAsync rejects non-positive stream id', () async {
      _expectValidationError(
        await repository.streamPollAsync(-2),
        'Invalid stream ID',
      );
    });

    test('cancelStream rejects non-positive stream id', () async {
      _expectValidationError(
        await repository.cancelStream(-3),
        'Invalid stream ID',
      );
    });

    test('detectDriver returns null for whitespace-only connection string',
        () async {
      expect(await repository.detectDriver('  \t\n  '), isNull);
    });

    test(
      'metadataCacheEnable rejects non-positive maxEntries or ttlSeconds',
      () async {
        _expectValidationError(
          await repository.metadataCacheEnable(maxEntries: -1, ttlSeconds: 60),
          'maxEntries and ttlSeconds must be greater than zero',
        );
        _expectValidationError(
          await repository.metadataCacheEnable(maxEntries: 10, ttlSeconds: 0),
          'maxEntries and ttlSeconds must be greater than zero',
        );
      },
    );

    test('setLogLevel rejects level above supported range', () async {
      _expectValidationError(
        await repository.setLogLevel(6),
        'Log level must be between 0 and 5',
      );
    });

    test(
      'connect rejects negative connectionTimeout before native call',
      () async {
        _expectValidationError(
          await repository.connect(
            'Driver={Test}',
            options: const ConnectionOptions(
              connectionTimeout: Duration(seconds: -1),
            ),
          ),
          'connectionTimeout cannot be negative',
        );
      },
    );
  });

  group('OdbcRepositoryImpl fake native error mapping', () {
    test(
      'initialize returns EnvironmentNotInitializedError when native false',
      () async {
        final native = _FakeAsyncNativeForRepositoryErrors()
          ..initializeSuccess = false;
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
        final native = _FakeAsyncNativeForRepositoryErrors();
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
        final native = _FakeAsyncNativeForRepositoryErrors()
          ..disconnectSuccess = false;
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

  group('OdbcRepositoryImpl wave 7b guards and error mapping', () {
    late _FakeAsyncNativeForRepositoryErrors native;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      native = _FakeAsyncNativeForRepositoryErrors();
      addTearDown(native.dispose);
      repository = OdbcRepositoryImpl(native);
      await repository.initialize();
      final conn = (await repository.connect('Driver={Test}')).getOrNull();
      expect(conn, isNotNull);
      connectionId = conn!.id;
    });

    test(
      'connect maps structured error when native connect returns zero',
      () async {
        native
          ..connectReturnsZero = true
          ..globalStructuredError = const StructuredError(
            sqlState: _sqlState0A000,
            nativeCode: 18456,
            message: 'Login failed for user',
          );
        final result = await repository.connect('Driver={Test}');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ConnectionError>());
            final err = e as ConnectionError;
            expect(err.message, 'Login failed for user');
            expect(err.sqlState, '0A000');
            expect(err.nativeCode, 18456);
          },
        );
      },
    );

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

    test(
      'executePrepared maps structured error when native returns null buffer',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..executePreparedResult = null
          ..globalStructuredError = const StructuredError(
            sqlState: [52, 50, 48, 48, 48],
            nativeCode: 102,
            message: 'Execute failed',
          );
        final result =
            await repository.executePrepared(connectionId, stmtId, []);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<QueryError>());
            final err = e as QueryError;
            expect(err.message, 'Execute failed');
            expect(err.nativeCode, 102);
          },
        );
      },
    );

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

    test(
      'cancelStatement maps unsupported cancellation structured error',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..cancelStatementSuccess = false
          ..globalStructuredError = const StructuredError(
            sqlState: _sqlState0A000,
            nativeCode: 5001,
            message: 'Unsupported feature: statement cancellation',
          );
        final result = await repository.cancelStatement(connectionId, stmtId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<UnsupportedFeatureError>());
            final err = e as UnsupportedFeatureError;
            expect(err.sqlState, '0A000');
            expect(err.nativeCode, 5001);
          },
        );
      },
    );

    test(
      'cancelStatement maps invalid statement id text to ValidationError',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        native
          ..cancelStatementSuccess = false
          ..globalStructuredError = null
          ..errorMessage = 'Invalid statement ID 999';
        final result = await repository.cancelStatement(connectionId, stmtId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              'Invalid statement ID 999',
            );
          },
        );
      },
    );

    test(
      'executeQueryNamed maps missing named parameters to ValidationError',
      () async {
        final result = await repository.executeQueryNamed(
          connectionId,
          'SELECT :id',
          <String, Object?>{},
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
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
          ..executeQueryMultiResult = _malformedMultiResultBuffer();
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
      'executeQueryMultiFull maps malformed multi buffer to QueryError',
      () async {
        native.executeQueryMultiResult = _malformedMultiResultBuffer();
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
  });
}
