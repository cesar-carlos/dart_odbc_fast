/// Unit tests for [OdbcRepositoryImpl].
///
/// Timeout and auto-reconnect behavior require a backend that delays or
/// returns connectionLost; see E2E or integration tests when ODBC is available.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_parser.dart';
import 'package:odbc_fast/infrastructure/native/protocol/multi_result_stream_decoder.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../helpers/fake_async_native_for_errors.dart';

/// Single multi-stream row-count frame (tag + u32 len + i64).
Uint8List _rowCountMultiStreamFrame(int n) {
  final payload = ByteData(8)..setInt64(0, n, Endian.little);
  final builder = BytesBuilder()
    ..addByte(multiStreamItemTagRowCount)
    ..add(
      (ByteData(4)..setUint32(0, 8, Endian.little)).buffer.asUint8List(),
    )
    ..add(payload.buffer.asUint8List());
  return builder.toBytes();
}

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

/// Local alias so existing call sites in this file keep using the short
/// underscore-prefixed name. New tests should import the helper directly
/// as [FakeAsyncNativeForRepositoryErrors] from `test/helpers/`.
typedef _FakeAsyncNativeForRepositoryErrors
    = FakeAsyncNativeForRepositoryErrors;

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
      'streamQueryMulti decodes row-count frame split across stream fetches',
      () async {
        final frame = _rowCountMultiStreamFrame(4242);
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

    group('dispose & disconnect cleanup', () {
      test(
        'should_clear_dart_side_state_after_dispose',
        () async {
          // Establish a fresh repo + connection so we have state to clear.
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();
          final connId =
              (await localRepo.connect('Driver={Test}')).getOrNull()!.id;

          // Sanity check: prepare succeeds against the live connection.
          final beforePrepare = await localRepo.prepare(connId, 'SELECT 1');
          expect(beforePrepare.isSuccess(), isTrue);

          localRepo.dispose();

          // After dispose, the same connectionId must read as invalid —
          // proving the Dart-side _connectionIds map was cleared.
          final afterPrepare = await localRepo.prepare(connId, 'SELECT 1');
          expect(afterPrepare.isError(), isTrue);
          afterPrepare.fold(
            (_) => fail('Expected failure after dispose'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Invalid connection ID'),
            ),
          );
        },
      );

      test(
        'should_clear_dart_state_when_disconnect_native_fails',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors()
            ..disconnectSuccess = false;
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();
          final connId =
              (await localRepo.connect('Driver={Test}')).getOrNull()!.id;

          final result = await localRepo.disconnect(connId);
          expect(result.isError(), isTrue);

          // Even though disconnect failed at the native layer, Dart-side
          // state must have been cleared so the next op fails fast with
          // ValidationError instead of misleading errors.
          final next = await localRepo.prepare(connId, 'SELECT 1');
          next.fold(
            (_) => fail('Expected failure after failed disconnect'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Invalid connection ID'),
            ),
          );
        },
      );
    });

    group('dartSideMetrics', () {
      test(
        'should_report_zero_counters_for_fresh_repository',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.connectionCount, 0);
          expect(metrics.statementCount, 0);
          expect(metrics.namedParamMetadataCount, 0);
          expect(metrics.pooledConnectionCount, 0);
          expect(metrics.poolCheckoutCount, 0);
          expect(metrics.connectionOptionsCount, 0);
        },
      );

      test(
        'should_track_connection_count_after_connect',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          await localRepo.connect('Driver={Test}');
          await localRepo.connect('Driver={Test}');

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.connectionCount, 2);
          expect(metrics.connectionOptionsCount, 2);
        },
      );

      test(
        'should_track_statementCount_and_namedParamMetadataCount',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final connId =
              (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
          // The fake returns the same stmtId (100) for every prepare, so the
          // statement map is keyed once. Both prepareNamed and prepare write
          // to the same metadata slot — what matters here is that the maps
          // are populated, not the exact count for distinct stmts.
          await localRepo.prepareNamed(connId, 'SELECT :x');

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.statementCount, greaterThanOrEqualTo(1));
          expect(metrics.namedParamMetadataCount, greaterThanOrEqualTo(1));
        },
      );

      test(
        'should_serialize_to_json_for_telemetry_exporters',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final json = localRepo.dartSideMetrics().toJson();
          expect(
            json.keys,
            containsAll([
              'connectionCount',
              'statementCount',
              'namedParamMetadataCount',
              'pooledConnectionCount',
              'poolCheckoutCount',
              'connectionOptionsCount',
            ]),
          );
        },
      );
    });

    group('worker recovery + events', () {
      test(
        'onWorkerRecovered should_clear_state_and_emit_WorkerRecovered_event',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final connId =
              (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
          // Seed statement metadata so we can prove it's cleared too.
          final prepareResult = await localRepo.prepare(connId, 'SELECT 1');
          expect(prepareResult.isSuccess(), isTrue);

          // Subscribe before triggering recovery so the broadcast stream
          // delivers the event synchronously.
          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          // Trigger the callback exactly as `_recoverWorkerInternal` does.
          final cb = localNative.onWorkerRecovered;
          expect(cb, isNotNull);
          cb!();

          expect(events, hasLength(1));
          expect(events.single, isA<WorkerRecovered>());

          // State must be cleared — old connectionId should now read as
          // invalid through any repository entrypoint.
          final after = await localRepo.prepare(connId, 'SELECT 1');
          expect(after.isError(), isTrue);
          after.fold(
            (_) => fail('Expected ValidationError after recovery'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Invalid connection ID'),
            ),
          );

          // The Dart-side metrics must reflect the clear-all.
          final metrics = localRepo.dartSideMetrics();
          expect(metrics.connectionCount, equals(0));
          expect(metrics.statementCount, equals(0));
        },
      );

      test(
        'onWorkerRecovered should_be_safe_when_no_listener_subscribed',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();
          await localRepo.connect('Driver={Test}');

          // No listener attached — _emit must short-circuit gracefully.
          expect(() => localNative.onWorkerRecovered!(), returnsNormally);
        },
      );

      test(
        'fromBackend constructor should_wire_recovery_callback',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          await localNative.initialize();

          final localRepo = OdbcRepositoryImpl.fromBackend(
            AsyncBackend(localNative),
          );
          addTearDown(localRepo.dispose);

          expect(localNative.onWorkerRecovered, isNotNull);

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          localNative.onWorkerRecovered!();
          expect(events.whereType<WorkerRecovered>(), hasLength(1));
        },
      );

      test(
        'events stream should_not_emit_after_dispose_closes_controller',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();
          await localRepo.connect('Driver={Test}');

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          await sub.cancel();
          localRepo.dispose();

          // Calling the recovery callback after dispose must not throw.
          expect(() => localNative.onWorkerRecovered?.call(), returnsNormally);
          expect(events, isEmpty);
        },
      );
    });

    group('statement lifecycle via fake', () {
      late _FakeAsyncNativeForRepositoryErrors localNative;
      late OdbcRepositoryImpl localRepo;
      late String connId;
      late int stmtId;

      setUp(() async {
        localNative = _FakeAsyncNativeForRepositoryErrors();
        addTearDown(localNative.dispose);
        localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        connId = (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
        stmtId = (await localRepo.prepare(connId, 'SELECT 1')).getOrNull()!;
      });

      test(
        'closeStatement should_succeed_and_clear_statement_metadata',
        () async {
          final r = await localRepo.closeStatement(connId, stmtId);
          expect(r.isSuccess(), isTrue);

          // Following call must now see the statement as unknown.
          final after = await localRepo.closeStatement(connId, stmtId);
          expect(after.isError(), isTrue);
          after.fold(
            (_) => fail('Expected ValidationError'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_clear_metadata_even_when_native_fails',
        () async {
          localNative
            ..closeStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 42,
              message: 'native close refused',
            );

          final r = await localRepo.closeStatement(connId, stmtId);
          expect(r.isError(), isTrue);

          // Even on failure, the Dart-side metadata must be wiped.
          final after = await localRepo.closeStatement(connId, stmtId);
          after.fold(
            (_) => fail('Expected ValidationError after wipe'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_reject_unknown_statement_id',
        () async {
          final r = await localRepo.closeStatement(connId, 999_999);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            ),
          );
        },
      );

      test(
        'closeStatement should_reject_statement_owned_by_other_connection',
        () async {
          final otherConn =
              (await localRepo.connect('Driver={Other}')).getOrNull()!.id;
          final r = await localRepo.closeStatement(otherConn, stmtId);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              contains('does not belong'),
            ),
          );
        },
      );

      test(
        'cancelStatement should_succeed_when_native_returns_true',
        () async {
          localNative.cancelStatementSuccess = true;
          final r = await localRepo.cancelStatement(connId, stmtId);
          expect(r.isSuccess(), isTrue);
        },
      );

      test(
        'cancelStatement should_translate_unsupported_sqlstate_0A000',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [48, 65, 48, 48, 48],
              nativeCode: 5001,
              message: 'cancellation not supported',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected UnsupportedFeatureError'),
            (e) {
              expect(e, isA<UnsupportedFeatureError>());
              expect(
                (e as UnsupportedFeatureError).sqlState,
                equals('0A000'),
              );
            },
          );
        },
      );

      test(
        'cancelStatement should_translate_unsupported_native_code_5001',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 5001,
              message: 'engine does not implement cancellation',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected UnsupportedFeatureError'),
            (e) => expect(e, isA<UnsupportedFeatureError>()),
          );
        },
      );

      test(
        'cancelStatement should_surface_query_error_for_unrelated_failure',
        () async {
          localNative
            ..cancelStatementSuccess = false
            ..errorMessage = 'driver is busy'
            ..globalStructuredError = const StructuredError(
              sqlState: [50, 53, 48, 48, 48],
              nativeCode: 99,
              message: '',
            );
          final r = await localRepo.cancelStatement(connId, stmtId);
          r.fold(
            (_) => fail('Expected QueryError'),
            (e) {
              expect(e, isA<QueryError>());
              final err = e as QueryError;
              expect(err.message, equals('driver is busy'));
            },
          );
        },
      );

      test(
        'cancelStatement should_reject_unknown_statement_id',
        () async {
          final r = await localRepo.cancelStatement(connId, 9_999_999);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(e, isA<ValidationError>()),
          );
        },
      );
    });

    group('transaction primitives via fake', () {
      late _FakeAsyncNativeForRepositoryErrors localNative;
      late OdbcRepositoryImpl localRepo;
      late String connId;

      setUp(() async {
        localNative = _FakeAsyncNativeForRepositoryErrors();
        addTearDown(localNative.dispose);
        localRepo = OdbcRepositoryImpl(localNative);
        await localRepo.initialize();
        connId = (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
      });

      test(
        'commitTransaction should_reject_zero_or_negative_txnId',
        () async {
          final zero = await localRepo.commitTransaction(connId, 0);
          final neg = await localRepo.commitTransaction(connId, -1);
          for (final r in [zero, neg]) {
            expect(r.isError(), isTrue);
            r.fold(
              (_) => fail('Expected ValidationError'),
              (e) => expect(
                (e as ValidationError).message,
                equals('Invalid transaction ID'),
              ),
            );
          }
        },
      );

      test(
        'commitTransaction should_forward_to_native_on_valid_txnId',
        () async {
          localNative.commitTransactionSuccess = true;
          final r = await localRepo.commitTransaction(connId, 12);
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(12));
        },
      );

      test(
        'commitTransaction should_surface_native_failure_as_QueryError',
        () async {
          localNative
            ..commitTransactionSuccess = false
            ..globalStructuredError = const StructuredError(
              sqlState: [52, 50, 48, 48, 48],
              nativeCode: 9999,
              message: 'commit failed at server',
            );
          final r = await localRepo.commitTransaction(connId, 12);
          expect(r.isError(), isTrue);
          r.fold(
            (_) => fail('Expected failure'),
            (e) {
              expect(e, isA<QueryError>());
              final err = e as QueryError;
              expect(err.message, equals('commit failed at server'));
              expect(err.sqlState, equals('42000'));
              expect(err.nativeCode, equals(9999));
            },
          );
        },
      );

      test(
        'rollbackTransaction should_forward_to_native_on_valid_txnId',
        () async {
          localNative.rollbackTransactionSuccess = true;
          final r = await localRepo.rollbackTransaction(connId, 99);
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(99));
        },
      );

      test(
        'rollbackTransaction should_reject_invalid_connection',
        () async {
          final r = await localRepo.rollbackTransaction('missing', 1);
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Invalid connection ID'),
            ),
          );
        },
      );

      group('savepoint operations', () {
        test('createSavepoint should_reject_empty_name_after_trim', () async {
          final r = await localRepo.createSavepoint(connId, 1, '   ');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Savepoint name cannot be empty'),
            ),
          );
        });

        test('createSavepoint should_reject_zero_txnId', () async {
          final r = await localRepo.createSavepoint(connId, 0, 'sp1');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Invalid transaction ID'),
            ),
          );
        });

        test('createSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.createSavepoint(connId, 7, 'sp_alpha');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_alpha'));
        });

        test('rollbackToSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.rollbackToSavepoint(connId, 7, 'sp_beta');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_beta'));
        });

        test('rollbackToSavepoint should_reject_empty_name', () async {
          final r = await localRepo.rollbackToSavepoint(connId, 7, '');
          r.fold(
            (_) => fail('Expected failure'),
            (e) => expect(
              (e as ValidationError).message,
              equals('Savepoint name cannot be empty'),
            ),
          );
        });

        test('releaseSavepoint should_forward_args_to_native', () async {
          final r = await localRepo.releaseSavepoint(connId, 7, 'sp_gamma');
          expect(r.isSuccess(), isTrue);
          expect(localNative.lastTxnId, equals(7));
          expect(localNative.lastSavepointName, equals('sp_gamma'));
        });

        test(
          'releaseSavepoint should_surface_failure_as_QueryError',
          () async {
            localNative
              ..releaseSavepointSuccess = false
              ..globalStructuredError = const StructuredError(
                sqlState: [52, 50, 48, 48, 48],
                nativeCode: 1234,
                message: 'release failed',
              );
            final r = await localRepo.releaseSavepoint(connId, 7, 'sp');
            r.fold(
              (_) => fail('Expected failure'),
              (e) {
                expect(e, isA<QueryError>());
                expect((e as QueryError).message, equals('release failed'));
              },
            );
          },
        );

        test(
          'savepoint methods should_reject_invalid_connection_id',
          () async {
            final c = await localRepo.createSavepoint('missing', 1, 'sp');
            final r = await localRepo.rollbackToSavepoint('missing', 1, 'sp');
            final rl = await localRepo.releaseSavepoint('missing', 1, 'sp');
            for (final res in [c, r, rl]) {
              res.fold(
                (_) => fail('Expected failure'),
                (e) => expect(
                  (e as ValidationError).message,
                  equals('Invalid connection ID'),
                ),
              );
            }
          },
        );
      });
    });

    group('slow query detection', () {
      test(
        'should_emit_SlowQueryDetected_when_threshold_is_zero_duration',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          // Threshold of Duration.zero means any non-zero elapsed time
          // crosses it — deterministic across CI runs.
          final conn = (await localRepo.connect(
            'Driver={Test}',
            options: const ConnectionOptions(
              slowQueryThreshold: Duration.zero,
            ),
          ))
              .getOrNull()!;

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          // executeQueryMultiFull threads `sqlForSlowQueryDetection` through
          // `_withReconnect`, exercising the slow-query hook with the fake.
          localNative.executeQueryMultiResult = Uint8List(0);
          final result = await localRepo.executeQueryMultiFull(
            conn.id,
            'SELECT 1',
          );
          expect(result.isSuccess(), isTrue);

          final slow = events.whereType<SlowQueryDetected>().toList();
          expect(slow, hasLength(1));
          expect(slow.single.connectionId, equals(conn.id));
          expect(slow.single.sql, equals('SELECT 1'));
        },
      );

      test(
        'should_not_emit_SlowQueryDetected_when_threshold_is_unset',
        () async {
          final localNative = _FakeAsyncNativeForRepositoryErrors();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final conn = (await localRepo.connect('Driver={Test}')).getOrNull()!;

          final events = <OdbcEvent>[];
          final sub = localRepo.events.listen(events.add);
          addTearDown(sub.cancel);

          localNative.executeQueryMultiResult = Uint8List(0);
          await localRepo.executeQueryMultiFull(conn.id, 'SELECT 1');

          expect(events.whereType<SlowQueryDetected>(), isEmpty);
        },
      );
    });
  });
}
