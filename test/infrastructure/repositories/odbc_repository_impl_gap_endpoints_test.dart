import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart'
    show OdbcMetrics, PreparedStatementMetrics;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

class _FakeAsyncNativeForGapErrors extends AsyncNativeOdbcConnection {
  _FakeAsyncNativeForGapErrors() : super(requestTimeout: Duration.zero);

  String errorMessage = 'native error';
  StructuredError? globalStructuredError;
  StructuredError? connectionStructuredError;

  bool initializeSuccess = true;

  /// When true, [connect] returns 0 to trigger connection failure mapping.
  bool connectReturnsZero = false;

  bool poolSetSizeSuccess = true;

  /// When false, [disconnect] surfaces [ConnectionError] from the repository.
  bool disconnectSuccess = true;

  /// Non-zero means failure in [OdbcRepositoryImpl.clearAllStatements].
  int clearAllStatementsCode = 0;
  int streamMultiStartBatchedResult = 0;
  Uint8List? executeQueryMultiResult = Uint8List(0);

  /// Native handles increment each call so each logical connection gets a
  /// distinct string id (`nativeId.toString()` in the repository).
  int _nextNativeConn = 41;

  @override
  Future<bool> initialize() async => initializeSuccess;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async {
    if (connectReturnsZero) return 0;
    return ++_nextNativeConn;
  }

  @override
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async =>
      0;

  @override
  Future<String?> validateConnectionString(String connectionString) async =>
      'rejected by fake';

  @override
  Future<int> prepare(
    int connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async =>
      100;

  @override
  Future<String> getError() async => errorMessage;

  @override
  Future<Uint8List?> executeQueryParams(
    int connectionId,
    String sql,
    List<ParamValue> params, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async =>
      null;

  @override
  Future<Uint8List?> executeQueryParamBuffer(
    int connectionId,
    String sql,
    Uint8List? paramBuffer, {
    int? maxBufferBytes,
    Duration? timeout,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async =>
      null;

  @override
  Future<StructuredError?> getStructuredError() async => globalStructuredError;

  @override
  Future<StructuredError?> getStructuredErrorForConnection(
    int connectionId,
  ) async =>
      connectionStructuredError;

  @override
  Future<String?> getDriverCapabilitiesJson(String connectionString) async =>
      '{invalid_json';

  @override
  Future<String?> getConnectionDbmsInfoJson(int connectionId) async =>
      '{invalid_json';

  @override
  Future<void> setLogLevel(int level) async {}

  @override
  Future<int> clearAllStatements() async => clearAllStatementsCode;

  @override
  Future<bool> poolSetSize(int poolId, int newMaxSize) async =>
      poolSetSizeSuccess;

  @override
  Future<int> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) async =>
      0;

  @override
  Future<bool> commitTransaction(int txnId) async => false;

  @override
  Future<bool> rollbackTransaction(int txnId) async => false;

  @override
  Future<bool> createSavepoint(int txnId, String name) async => false;

  @override
  Future<bool> rollbackToSavepoint(int txnId, String name) async => false;

  @override
  Future<bool> releaseSavepoint(int txnId, String name) async => false;

  @override
  Future<Uint8List?> catalogTables(
    int connectionId, {
    String catalog = '',
    String schema = '',
  }) async =>
      null;

  @override
  Future<Uint8List?> catalogColumns(int connectionId, String table) async =>
      null;

  @override
  Future<Uint8List?> catalogTypeInfo(int connectionId) async => null;

  @override
  Future<Uint8List?> catalogPrimaryKeys(
    int connectionId,
    String table,
  ) async =>
      null;

  @override
  Future<Uint8List?> catalogForeignKeys(
    int connectionId,
    String table,
  ) async =>
      null;

  @override
  Future<Uint8List?> catalogIndexes(
    int connectionId,
    String table,
  ) async =>
      null;

  @override
  Future<int> bulkInsertArray(
    int connectionId,
    String table,
    List<String> columns,
    Uint8List dataBuffer,
    int rowCount,
  ) async =>
      -1;

  @override
  Future<int> poolGetConnection(int poolId) async => 0;

  @override
  Future<bool> poolHealthCheck(int poolId) async => false;

  @override
  Future<bool> closeStatement(int stmtId) async => true;

  @override
  Future<bool> cancelStatement(int stmtId) async => true;

  @override
  Future<bool> disconnect(int connectionId) async => disconnectSuccess;

  @override
  Future<({int size, int idle})?> poolGetState(int poolId) async => null;

  @override
  Future<bool> poolClose(int poolId) async => false;

  @override
  Future<bool> clearAuditEvents() async => false;

  @override
  Future<bool> setAuditEnabled({required bool enabled}) async => false;

  @override
  Future<OdbcMetrics?> getMetrics() async => null;

  @override
  Future<Map<String, String>?> getVersion() async => null;

  @override
  Future<PreparedStatementMetrics?> getCacheMetrics() async => null;

  @override
  Future<bool> clearStatementCache() async => false;

  @override
  Future<bool> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async =>
      false;

  @override
  Future<bool> clearMetadataCache() async => false;

  @override
  Future<String?> getAuditStatusJson() async => '[]';

  @override
  Future<String?> getAuditEventsJson({int limit = 0}) async => '{}';

  @override
  Future<String?> getMetadataCacheStatsJson() async => '{bad_json';

  @override
  Future<String?> poolGetStateJson(int poolId) async => '{bad_json';

  @override
  Future<int> executeAsyncStart(int connectionId, String sql) async => 0;

  @override
  Future<int> streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async =>
      0;

  @override
  Future<int> asyncPoll(int asyncRequestId) async => 1;

  @override
  Future<Uint8List?> asyncGetResult(
    int asyncRequestId, {
    int? maxBufferBytes,
  }) async =>
      null;

  @override
  Future<bool> asyncCancel(int asyncRequestId) async => false;

  @override
  Future<bool> asyncFree(int asyncRequestId) async => false;

  @override
  Future<bool> streamCancel(int streamId) async => false;

  @override
  Future<int> streamPollAsync(int streamId) async => 7;

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
  Future<Uint8List?> executeQueryMultiParams(
    int connectionId,
    String sql,
    Uint8List? paramsBuffer, {
    int? maxBufferBytes,
  }) async =>
      null;

  @override
  Future<String?> detectDriver(String connectionString) async => 'TestDriver';

  @override
  void dispose() {}
}

/// [poolGetConnection] returns a non-zero id; [poolReleaseConnection] fails.
class _FakePoolReleaseConnectionFails extends _FakeAsyncNativeForGapErrors {
  @override
  Future<int> poolGetConnection(int poolId) async => 200;

  @override
  Future<bool> poolReleaseConnection(int connectionId) async => false;
}

class _FakePoolBeginTransactionSucceeds extends _FakeAsyncNativeForGapErrors {
  int? lastBeginConnectionId;

  @override
  Future<int> poolGetConnection(int poolId) async => 200;

  @override
  Future<int> beginTransaction(
    int connectionId,
    int isolationLevel, {
    int savepointDialect = 0,
    int accessMode = 0,
    int lockTimeoutMs = 0,
  }) async {
    lastBeginConnectionId = connectionId;
    return 300;
  }
}

void main() {
  group('OdbcRepositoryImpl new endpoint error paths', () {
    late _FakeAsyncNativeForGapErrors asyncNative;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      asyncNative = _FakeAsyncNativeForGapErrors();
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
      final connResult = await repository.connect('DSN=Fake');
      final connection = connResult.getOrNull();
      expect(connection, isNotNull);
      connectionId = connection!.id;
    });

    test('getDriverCapabilities returns QueryError for invalid JSON', () async {
      final result = await repository.getDriverCapabilities('DSN=Fake');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('getConnectionDbmsInfo returns QueryError for invalid JSON', () async {
      final result = await repository.getConnectionDbmsInfo(connectionId);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('setLogLevel validates range', () async {
      final high = await repository.setLogLevel(9);
      expect(high.isSuccess(), isFalse);
      high.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ValidationError>()),
      );
      final low = await repository.setLogLevel(-1);
      expect(low.isSuccess(), isFalse);
      low.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ValidationError>()),
      );
    });

    test(
      'xaStart returns ValidationError when XA is unsupported on async backend',
      () async {
        final result = await repository.xaStart(
          connectionId,
          Xid.fromStrings(gtrid: 'g'),
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('async ODBC repository'),
            );
          },
        );
      },
    );

    test(
      'executePrepared returns ValidationError when statement id is unknown',
      () async {
        final result =
            await repository.executePrepared(connectionId, 99999, []);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            );
          },
        );
      },
    );

    test(
      'executePrepared returns ValidationError when statement belongs to '
      'another connection',
      () async {
        final conn2 = await repository.connect('DSN=Other');
        final id2 = conn2.getOrNull()!.id;
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        final result = await repository.executePrepared(id2, stmtId, []);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('does not belong'),
            );
          },
        );
      },
    );

    test(
      'executePreparedNamed returns ValidationError when statement was not '
      'created with prepareNamed',
      () async {
        final prep = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prep.getOrNull()!;
        final result = await repository.executePreparedNamed(
          connectionId,
          stmtId,
          {},
          null,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('prepareNamed'),
            );
          },
        );
      },
    );

    test(
      'executePreparedNamed maps ParameterMissingException to ValidationError',
      () async {
        final prep = await repository.prepareNamed(connectionId, 'SELECT :a');
        final stmtId = prep.getOrNull()!;
        final result = await repository.executePreparedNamed(
          connectionId,
          stmtId,
          {},
          null,
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
      'closeStatement returns ValidationError when statement id is unknown',
      () async {
        final result = await repository.closeStatement(connectionId, 88888);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('closeStatement'),
            );
          },
        );
      },
    );

    test(
      'closeStatement returns ValidationError when statement belongs to '
      'another connection',
      () async {
        final conn2 = await repository.connect('DSN=CloseStmtOther');
        final id2 = conn2.getOrNull()!.id;
        await repository.prepare(connectionId, 'SELECT 1');
        final result = await repository.closeStatement(id2, 100);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('does not belong'),
            );
          },
        );
      },
    );

    test(
      'cancelStatement returns ValidationError when statement id is unknown',
      () async {
        final result = await repository.cancelStatement(connectionId, 77777);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('cancelStatement'),
            );
          },
        );
      },
    );

    test(
      'cancelStatement returns ValidationError when statement belongs to '
      'another connection',
      () async {
        final conn2 = await repository.connect('DSN=CancelStmtOther');
        final id2 = conn2.getOrNull()!.id;
        await repository.prepare(connectionId, 'SELECT 1');
        final result = await repository.cancelStatement(id2, 100);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('does not belong'),
            );
          },
        );
      },
    );

    test('clearAllStatements succeeds when native returns zero', () async {
      final result = await repository.clearAllStatements();
      expect(result.isSuccess(), isTrue);
    });

    test(
      'clearAllStatements invalidates repository-side prepared statement '
      'metadata',
      () async {
        final prepared = await repository.prepare(connectionId, 'SELECT 1');
        final stmtId = prepared.getOrNull();
        expect(stmtId, isNotNull);

        final clearResult = await repository.clearAllStatements();
        expect(clearResult.isSuccess(), isTrue);

        final executeResult =
            await repository.executePrepared(connectionId, stmtId!, []);
        expect(executeResult.isSuccess(), isFalse);
        executeResult.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('Unknown statement ID'),
            );
          },
        );
      },
    );

    test(
      'clearAllStatements returns QueryError when native returns non-zero '
      'code',
      () async {
        asyncNative.clearAllStatementsCode = 7;
        final result = await repository.clearAllStatements();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'streamQueryMulti falls back to full execution when async stream start '
      'returns zero',
      () async {
        asyncNative
          ..streamMultiStartBatchedResult = 0
          ..executeQueryMultiResult = Uint8List(0);

        final items = await repository
            .streamQueryMulti(connectionId, 'SELECT 1')
            .toList();

        expect(items, isEmpty);
      },
    );

    test('poolSetSize succeeds when native returns true', () async {
      final result = await repository.poolSetSize(1, 4);
      expect(result.isSuccess(), isTrue);
    });

    test(
      'poolSetSize returns ConnectionError when native returns false',
      () async {
        asyncNative.poolSetSizeSuccess = false;
        final result = await repository.poolSetSize(1, 4);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );

    test(
      'poolCreate returns ConnectionError when native returns zero pool id',
      () async {
        final result = await repository.poolCreate('DSN=Pool', 3);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );

    test(
      'commitTransaction returns QueryError when native returns false',
      () async {
        final result = await repository.commitTransaction(connectionId, 1);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'rollbackTransaction returns QueryError when native returns false',
      () async {
        final result = await repository.rollbackTransaction(connectionId, 1);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'createSavepoint returns QueryError when native returns false',
      () async {
        final result = await repository.createSavepoint(connectionId, 9, 'sp');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'rollbackToSavepoint returns QueryError when native returns false',
      () async {
        final result =
            await repository.rollbackToSavepoint(connectionId, 9, 'sp');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'releaseSavepoint returns QueryError when native returns false',
      () async {
        final result = await repository.releaseSavepoint(connectionId, 9, 'sp');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogTables returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogTables(connectionId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogColumns returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogColumns(connectionId, 't');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogTypeInfo returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogTypeInfo(connectionId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogPrimaryKeys returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogPrimaryKeys(connectionId, 't');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogForeignKeys returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogForeignKeys(connectionId, 't');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'catalogIndexes returns QueryError when native returns null buffer',
      () async {
        final result = await repository.catalogIndexes(connectionId, 't');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'bulkInsert returns QueryError when native returns negative row count',
      () async {
        final result = await repository.bulkInsert(
          connectionId,
          't',
          const ['c'],
          Uint8List(0),
          0,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'disconnect returns ConnectionError when native returns false',
      () async {
        asyncNative.disconnectSuccess = false;
        final result = await repository.disconnect(connectionId);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );

    test('poolHealthCheck returns failure with native false', () async {
      // Native false → pool invalid/unhealthy → Failure(ConnectionError).
      final result = await repository.poolHealthCheck(1);
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ConnectionError>());
    });

    test('closeStatement succeeds when native returns true', () async {
      await repository.prepare(connectionId, 'SELECT 1');
      final result = await repository.closeStatement(connectionId, 100);
      expect(result.isSuccess(), isTrue);
    });

    test('cancelStatement succeeds when native returns true', () async {
      await repository.prepare(connectionId, 'SELECT 1');
      final result = await repository.cancelStatement(connectionId, 100);
      expect(result.isSuccess(), isTrue);
    });

    test(
      'poolGetConnection returns ConnectionError when native returns zero',
      () async {
        final result = await repository.poolGetConnection(1);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ConnectionError>());
          },
        );
      },
    );

    test(
      'poolGetState returns ConnectionError when native returns null tuple',
      () async {
        final result = await repository.poolGetState(1);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );

    test(
      'poolClose returns ConnectionError when native returns false',
      () async {
        final result = await repository.poolClose(1);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );

    test(
      'getMetrics returns QueryError when native returns null metrics',
      () async {
        final result = await repository.getMetrics();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'getVersion returns QueryError when native returns null version map',
      () async {
        final result = await repository.getVersion();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'clearStatementCache returns QueryError when native returns false',
      () async {
        final result = await repository.clearStatementCache();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'getPreparedStatementsMetrics returns QueryError when native returns '
      'null metrics',
      () async {
        final result = await repository.getPreparedStatementsMetrics();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'beginTransaction returns QueryError when native returns zero txn id',
      () async {
        final result = await repository.beginTransaction(
          connectionId,
          IsolationLevel.readCommitted,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'validateConnectionString returns ValidationError when native returns '
      'error text',
      () async {
        final result =
            await repository.validateConnectionString('DSN=ValidateTest');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              'rejected by fake',
            );
          },
        );
      },
    );

    test(
      'setAuditEnabled returns UnsupportedFeatureError when native returns '
      'false',
      () async {
        final result = await repository.setAuditEnabled(enabled: true);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<UnsupportedFeatureError>()),
        );
      },
    );

    test(
      'clearAuditEvents returns UnsupportedFeatureError when native returns '
      'false',
      () async {
        final result = await repository.clearAuditEvents();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<UnsupportedFeatureError>()),
        );
      },
    );

    test(
      'metadataCacheEnable returns UnsupportedFeatureError when native '
      'returns false',
      () async {
        final result = await repository.metadataCacheEnable(
          maxEntries: 100,
          ttlSeconds: 60,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<UnsupportedFeatureError>()),
        );
      },
    );

    test(
      'clearMetadataCache returns UnsupportedFeatureError when native '
      'returns false',
      () async {
        final result = await repository.clearMetadataCache();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<UnsupportedFeatureError>()),
        );
      },
    );

    test('getAuditStatus returns QueryError for invalid payload format',
        () async {
      final result = await repository.getAuditStatus();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect(
            (e as QueryError).message,
            contains('Invalid audit status payload format'),
          );
        },
      );
    });

    test('getAuditEvents returns QueryError for invalid payload format',
        () async {
      final result = await repository.getAuditEvents();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect(
            (e as QueryError).message,
            contains('Invalid audit events payload format'),
          );
        },
      );
    });

    test('metadataCacheStats returns QueryError for invalid JSON', () async {
      final result = await repository.metadataCacheStats();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('poolGetStateDetailed returns QueryError for invalid JSON', () async {
      final result = await repository.poolGetStateDetailed(1);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('executeAsyncStart returns failure when native returns zero',
        () async {
      final result =
          await repository.executeAsyncStart(connectionId, 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<UnsupportedFeatureError>()),
      );
    });

    test('streamStartAsync returns failure when native returns zero', () async {
      final result =
          await repository.streamStartAsync(connectionId, 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<UnsupportedFeatureError>()),
      );
    });

    test(
      'executeQueryParams returns QueryError when native returns null buffer',
      () async {
        final result = await repository.executeQueryParams(
          connectionId,
          'SELECT 1',
          <dynamic>[],
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'executeQueryParamBuffer returns QueryError when native returns null '
      'buffer',
      () async {
        final result = await repository.executeQueryParamBuffer(
          connectionId,
          'SELECT ?',
          null,
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test('detectDriver returns worker driver name', () async {
      final name = await repository.detectDriver('DSN=Any');
      expect(name, 'TestDriver');
    });

    test('asyncPoll returns success with native status', () async {
      final result = await repository.asyncPoll(42);
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), 1);
    });

    test(
      'asyncGetResult returns QueryError when native returns null buffer',
      () async {
        final result = await repository.asyncGetResult(5);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test('asyncCancel returns QueryError when native returns false', () async {
      final result = await repository.asyncCancel(3);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<QueryError>()),
      );
    });

    test('asyncFree returns QueryError when native returns false', () async {
      final result = await repository.asyncFree(3);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<QueryError>()),
      );
    });

    test('streamPollAsync returns success with native code', () async {
      final result = await repository.streamPollAsync(9);
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), 7);
    });

    test(
      'cancelStream returns UnsupportedFeatureError when native returns false',
      () async {
        final result = await repository.cancelStream(2);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<UnsupportedFeatureError>()),
        );
      },
    );

    test(
      'executeQueryMultiFull maps null native buffer to empty multi-result',
      () async {
        final result = await repository.executeQueryMultiFull(
          connectionId,
          'SELECT 1',
        );
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull()!.items, isEmpty);
      },
    );

    test(
      'executeQueryMultiParams maps null native buffer to empty multi-result',
      () async {
        final result = await repository.executeQueryMultiParams(
          connectionId,
          'SELECT 1',
          <dynamic>[],
        );
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull()!.items, isEmpty);
      },
    );

    test(
      'executeQueryNamed returns QueryError when native execute yields null',
      () async {
        final result = await repository.executeQueryNamed(
          connectionId,
          'SELECT :a',
          <String, Object?>{'a': 1},
        );
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<QueryError>()),
        );
      },
    );

    test(
      'validateConnectionString returns ValidationError when string is empty',
      () async {
        final result = await repository.validateConnectionString('');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('cannot be empty'),
            );
          },
        );
      },
    );

    test(
      'getDriverCapabilities returns ValidationError when string is empty',
      () async {
        final result = await repository.getDriverCapabilities('');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test(
      'getConnectionDbmsInfo returns ValidationError for unknown connection '
      'id',
      () async {
        final result =
            await repository.getConnectionDbmsInfo('no-such-connection');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect((e as ValidationError).message, contains('Invalid'));
          },
        );
      },
    );

    test(
      'poolCreate returns ValidationError when connection string is empty',
      () async {
        final result = await repository.poolCreate('', 3);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test(
      'poolCreate returns ValidationError when maxSize is not positive',
      () async {
        final result = await repository.poolCreate('DSN=Pool', 0);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('greater than zero'),
            );
          },
        );
      },
    );

    test('poolSetSize returns ValidationError when poolId is not positive',
        () async {
      final result = await repository.poolSetSize(0, 4);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, contains('Invalid pool ID'));
        },
      );
    });

    test(
      'poolSetSize returns ValidationError when newMaxSize is not positive',
      () async {
        final result = await repository.poolSetSize(1, 0);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect(
              (e as ValidationError).message,
              contains('greater than zero'),
            );
          },
        );
      },
    );

    test(
      'poolReleaseConnection returns ValidationError for unknown connection '
      'id',
      () async {
        final result =
            await repository.poolReleaseConnection('not-in-repository');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test('asyncPoll returns ValidationError when request id is invalid',
        () async {
      final result = await repository.asyncPoll(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect(
            (e as ValidationError).message,
            contains('async request ID'),
          );
        },
      );
    });

    test(
      'asyncGetResult returns ValidationError when request id is invalid',
      () async {
        final result = await repository.asyncGetResult(0);
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test('asyncCancel returns ValidationError when request id is invalid',
        () async {
      final result = await repository.asyncCancel(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ValidationError>()),
      );
    });

    test('asyncFree returns ValidationError when request id is invalid',
        () async {
      final result = await repository.asyncFree(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ValidationError>()),
      );
    });

    test('streamPollAsync returns ValidationError when stream id is invalid',
        () async {
      final result = await repository.streamPollAsync(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<ValidationError>());
          expect((e as ValidationError).message, contains('stream ID'));
        },
      );
    });

    test('cancelStream returns ValidationError when stream id is invalid',
        () async {
      final result = await repository.cancelStream(0);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ValidationError>()),
      );
    });

    test(
      'metadataCacheEnable returns ValidationError when maxEntries or ttl '
      'is not positive',
      () async {
        final bad = await repository.metadataCacheEnable(
          maxEntries: 0,
          ttlSeconds: 10,
        );
        expect(bad.isSuccess(), isFalse);
        bad.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
        final badTtl = await repository.metadataCacheEnable(
          maxEntries: 10,
          ttlSeconds: 0,
        );
        expect(badTtl.isSuccess(), isFalse);
        badTtl.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test(
      'executeAsyncStart returns ValidationError for unknown connection id',
      () async {
        final result =
            await repository.executeAsyncStart('unknown', 'SELECT 1');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test(
      'streamStartAsync returns ValidationError for unknown connection id',
      () async {
        final result = await repository.streamStartAsync('unknown', 'SELECT 1');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ValidationError>()),
        );
      },
    );

    test('detectDriver returns null when connection string is empty', () async {
      final name = await repository.detectDriver('');
      expect(name, isNull);
    });
  });

  group('OdbcRepositoryImpl pool release', () {
    test(
      'beginTransaction accepts connection obtained from poolGetConnection',
      () async {
        final native = _FakePoolBeginTransactionSucceeds();
        addTearDown(native.dispose);
        final repo = OdbcRepositoryImpl(native);
        await repo.initialize();

        final pooled = await repo.poolGetConnection(1);
        expect(pooled.isSuccess(), isTrue);
        final connectionId = pooled.getOrNull()!.id;

        final txn = await repo.beginTransaction(
          connectionId,
          IsolationLevel.readCommitted,
        );

        expect(txn.isSuccess(), isTrue);
        expect(txn.getOrNull(), 300);
        expect(native.lastBeginConnectionId, 200);
      },
    );

    test(
      'poolReleaseConnection returns ConnectionError when native returns '
      'false',
      () async {
        final native = _FakePoolReleaseConnectionFails();
        addTearDown(native.dispose);
        final repo = OdbcRepositoryImpl(native);
        await repo.initialize();
        final got = await repo.poolGetConnection(1);
        expect(got.isSuccess(), isTrue);
        final cid = got.getOrNull()!.id;
        final released = await repo.poolReleaseConnection(cid);
        expect(released.isSuccess(), isFalse);
        released.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<ConnectionError>()),
        );
      },
    );
  });

  group('OdbcRepositoryImpl initialize and connect failures', () {
    test(
      'initialize returns EnvironmentNotInitializedError when native false',
      () async {
        final n = _FakeAsyncNativeForGapErrors()..initializeSuccess = false;
        addTearDown(n.dispose);
        final repo = OdbcRepositoryImpl(n);
        final result = await repo.initialize();
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) => expect(e, isA<EnvironmentNotInitializedError>()),
        );
      },
    );

    test('connect returns ConnectionError when native returns zero', () async {
      final n = _FakeAsyncNativeForGapErrors()..connectReturnsZero = true;
      addTearDown(n.dispose);
      final repo = OdbcRepositoryImpl(n);
      final init = await repo.initialize();
      expect(init.isSuccess(), isTrue);
      final result = await repo.connect('DSN=Zero');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<ConnectionError>()),
      );
    });
  });
}
