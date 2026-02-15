// Integration tests for OdbcService.
///
/// These tests verify that OdbcService operations work correctly.
library;

import 'dart:io';

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/entities/query_result.dart';
import 'package:odbc_fast/domain/entities/query_result_multi.dart';
import 'package:odbc_fast/domain/entities/statement_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart'
    show loadOdbcLibraryFromPath;
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

import '../../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('OdbcService basic operations', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('Initialize service', () async {
      final result = await service.initialize();
      expect(result.isSuccess(), isTrue);
      expect(service.isInitialized(), isTrue);
      expect(mockRepo.initializeCalled, isTrue);
    });

    test('Initialize service with custom library path', () async {
      final sep = Platform.pathSeparator;
      final name = Platform.isWindows ? 'odbc_engine.dll' : 'libodbc_engine.so';
      final customPath =
          '${Directory.current.path}${sep}native${sep}target${sep}release'
          '$sep$name';
      final lib = loadOdbcLibraryFromPath(customPath);
      expect(lib, isNotNull);
    });

    test('Connect operation', () async {
      await service.initialize();
      final result = await service.connect('test-connection-string');
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()?.id, isNotEmpty);
      expect(mockRepo.connectCalled, isTrue);
    });

    test('Disconnect operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final disconnectResult =
          await service.disconnect(connResult.getOrNull()!.id);
      expect(disconnectResult.isSuccess(), isTrue);
      expect(mockRepo.disconnectCalled, isTrue);
    });

    test('ExecuteQueryParams operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryParams(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = ?',
        [1],
      );
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull()!.rows.length, equals(1));
      expect(mockRepo.executeQueryParamsCalled, isTrue);
    });

    test('PrepareNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.prepareNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.prepareNamedCalled, isTrue);
    });

    test('ExecutePreparedNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final stmtResult = await service.prepareNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
      );
      final result = await service.executePreparedNamed(
        connResult.getOrNull()!.id,
        stmtResult.getOrNull()!,
        {'id': 1},
        null,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.executePreparedNamedCalled, isTrue);
    });

    test('ExecuteQueryNamed operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryNamed(
        connResult.getOrNull()!.id,
        'SELECT * FROM users WHERE id = :id',
        {'id': 1},
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.executeQueryNamedCalled, isTrue);
    });

    test('ExecuteQueryMultiFull operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.executeQueryMultiFull(
        connResult.getOrNull()!.id,
        'SELECT 1; UPDATE users SET active = 1',
      );
      expect(result.isSuccess(), isTrue);
      final multi = result.getOrNull();
      expect(multi, isNotNull);
      expect(multi!.items.length, equals(2));
      expect(multi.resultSets.length, equals(1));
      expect(multi.rowCounts.length, equals(1));
      expect(mockRepo.executeQueryMultiFullCalled, isTrue);
    });

    test('BeginTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final result = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), greaterThan(0));
      expect(mockRepo.beginTransactionCalled, isTrue);
    });

    test('CommitTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      final result = await service.commitTransaction(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.commitTransactionCalled, isTrue);
    });

    test('RollbackTransaction operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
      );
      final result = await service.rollbackTransaction(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
      );
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.rollbackTransactionCalled, isTrue);
    });

    test('CreateSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.createSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('RollbackToSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.rollbackToSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('ReleaseSavepoint operation', () async {
      await service.initialize();
      final connResult = await service.connect('test');
      final txnResult = await service.beginTransaction(
        connResult.getOrNull()!.id,
        isolationLevel: IsolationLevel.readCommitted,
      );
      final result = await service.releaseSavepoint(
        connResult.getOrNull()!.id,
        txnResult.getOrNull()!,
        'savepoint1',
      );
      expect(result.isSuccess(), isTrue);
    });

    test('GetMetrics operation', () async {
      await service.initialize();
      final result = await service.getMetrics();
      expect(result.isSuccess(), isTrue);
      final metrics = result.getOrNull();
      expect(metrics, isNotNull);
      expect(metrics!.queryCount, equals(0)); // No queries executed yet
    });

    test('ClearStatementCache operation', () async {
      await service.initialize();
      final result = await service.clearStatementCache();
      expect(result.isSuccess(), isTrue);
      expect(mockRepo.clearStatementCacheCalled, isTrue);
    });

    test('StatementOptions functionality - timeout override', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(timeout: Duration(seconds: 5)),
      );
      expect(result.isSuccess(), isTrue);
    });

    test('StatementOptions functionality - fetchSize override', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(fetchSize: 500),
      );
      expect(result.isSuccess(), isTrue);
    });

    test('StatementOptions functionality - both options', () async {
      await service.initialize();
      final result = await service.executePrepared(
        'conn-1',
        1,
        [],
        const StatementOptions(
          timeout: Duration(seconds: 10),
          fetchSize: 250,
        ),
      );
      expect(result.isSuccess(), isTrue);
    });
  });

  if (getTestEnv('ODBC_TEST_DSN') == null) {
    return;
  }

  group('OdbcService E2E', () {
    ServiceLocator? locator;
    String? dsn;
    String? skipReason;

    setUpAll(() async {
      dsn = getTestEnv('ODBC_TEST_DSN');
      if (dsn == null || dsn!.isEmpty) {
        skipReason = 'ODBC_TEST_DSN not configured';
        return;
      }
      try {
        final sl = ServiceLocator()..initialize(useAsync: true);
        await sl.syncService.initialize();
        await sl.asyncService.initialize();
        locator = sl;
      } on Object catch (e) {
        skipReason = 'Native environment unavailable: $e';
      }
    });

    tearDownAll(() {
      locator?.shutdown();
    });

    test(
      'should connect and execute query with real ODBC',
      () async {
        if (skipReason != null ||
            dsn == null ||
            dsn!.isEmpty ||
            locator == null) {
          return;
        }

        final connResult = await locator!.syncService.connect(dsn!);
        final connection =
            connResult.getOrElse((_) => throw Exception('Failed to connect'));

        final queryResult = await locator!.syncService.executeQueryParams(
          connection.id,
          'SELECT 1',
          [],
        );

        expect(queryResult.isSuccess(), isTrue);
        await locator!.syncService.disconnect(connection.id);
      },
    );
  });
}

/// Mock ODBC repository for testing.
class MockOdbcRepository implements IOdbcRepository {
  Connection _connection = Connection(
    id: 'test-connection',
    connectionString: 'init',
    createdAt: DateTime.now(),
  );

  bool initializeCalled = false;
  bool connectCalled = false;
  bool disconnectCalled = false;
  bool executeQueryCalled = false;
  bool executeQueryParamsCalled = false;
  bool executeQueryNamedCalled = false;
  bool executeQueryMultiFullCalled = false;
  bool beginTransactionCalled = false;
  bool commitTransactionCalled = false;
  bool rollbackTransactionCalled = false;
  bool clearStatementCacheCalled = false;
  bool prepareNamedCalled = false;
  bool executePreparedNamedCalled = false;
  int _queryCount = 0;

  @override
  Future<Result<Unit>> initialize() async {
    initializeCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    connectCalled = true;
    _connection = Connection(
      id: 'test-connection-2',
      connectionString: connectionString,
      createdAt: DateTime.now(),
    );
    return Success(_connection);
  }

  @override
  Future<Result<Unit>> disconnect(String connectionId) async {
    disconnectCalled = true;
    if (connectionId == _connection.id) {
      _connection = Connection(
        id: '',
        connectionString: '',
        createdAt: DateTime.now(),
      );
      return const Success(unit);
    }
    return const Failure(
      ConnectionError(message: 'Connection ID does not match'),
    );
  }

  @override
  Future<Result<QueryResult>> executeQuery(
    String connectionId,
    String sql,
  ) async {
    executeQueryCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Alice'],
          [2, 'Bob'],
        ],
        rowCount: 2,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params,
  ) async {
    executeQueryParamsCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executeQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async {
    executeQueryNamedCalled = true;
    _queryCount++;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<int>> prepare(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    return const Success(1);
  }

  @override
  Future<Result<int>> prepareNamed(
    String connectionId,
    String sql, {
    int timeoutMs = 0,
  }) async {
    prepareNamedCalled = true;
    return const Success(2);
  }

  @override
  Future<Result<QueryResult>> executePrepared(
    String connectionId,
    int stmtId,
    List<dynamic>? params,
    StatementOptions? options,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> executePreparedNamed(
    String connectionId,
    int stmtId,
    Map<String, Object?> namedParams,
    StatementOptions? options,
  ) async {
    executePreparedNamedCalled = true;
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Charlie'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<Unit>> closeStatement(String connectionId, int stmtId) async {
    return const Success(unit);
  }

  @override
  Future<Result<int>> beginTransaction(
    String connectionId,
    IsolationLevel isolationLevel,
  ) async {
    beginTransactionCalled = true;
    return const Success(1);
  }

  @override
  Future<Result<Unit>> commitTransaction(
    String connectionId,
    int txnId,
  ) async {
    commitTransactionCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> rollbackTransaction(
    String connectionId,
    int txnId,
  ) async {
    rollbackTransactionCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> createSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> rollbackToSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<Unit>> releaseSavepoint(
    String connectionId,
    int txnId,
    String name,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<QueryResult>> executeQueryMulti(
    String connectionId,
    String sql,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [
          [1, 'Dave'],
        ],
        rowCount: 1,
      ),
    );
  }

  @override
  Future<Result<QueryResultMulti>> executeQueryMultiFull(
    String connectionId,
    String sql,
  ) async {
    executeQueryMultiFullCalled = true;
    return const Success(
      QueryResultMulti(
        items: [
          QueryResultMultiItem.resultSet(
            QueryResult(
              columns: ['id', 'name'],
              rows: [
                [1, 'Dave'],
              ],
              rowCount: 1,
            ),
          ),
          QueryResultMultiItem.rowCount(1),
        ],
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTables(
    String connectionId, {
    String catalog = '',
    String schema = '',
  }) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogColumns(
    String connectionId,
    String table,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<QueryResult>> catalogTypeInfo(
    String connectionId,
  ) async {
    return const Success(
      QueryResult(
        columns: ['id', 'name'],
        rows: [],
        rowCount: 0,
      ),
    );
  }

  @override
  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize,
  ) async {
    return const Success(1);
  }

  @override
  Future<Result<Connection>> poolGetConnection(
    int poolId,
  ) async {
    return Success(
      Connection(
        id: 'pooled',
        connectionString: 'pool',
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<Result<Unit>> poolReleaseConnection(
    String connectionId,
  ) async {
    return const Success(unit);
  }

  @override
  Future<Result<bool>> poolHealthCheck(int poolId) async {
    return const Success(true);
  }

  @override
  Future<Result<PoolState>> poolGetState(int poolId) async {
    return const Success(PoolState(size: 1, idle: 0));
  }

  @override
  Future<Result<Unit>> poolClose(int poolId) async {
    return const Success(unit);
  }

  @override
  Future<Result<int>> bulkInsert(
    String connectionId,
    String table,
    List<String> columns,
    List<int> dataBuffer,
    int rowCount,
  ) async {
    return const Success(0);
  }

  @override
  Future<Result<OdbcMetrics>> getMetrics() async {
    return Success(
      OdbcMetrics(
        queryCount: _queryCount,
        errorCount: 0,
        uptimeSecs: 10,
        totalLatencyMillis: 100,
        avgLatencyMillis: 25,
      ),
    );
  }

  @override
  bool isInitialized() {
    return _connection.id.isNotEmpty;
  }

  @override
  Future<Result<Unit>> clearStatementCache() async {
    clearStatementCacheCalled = true;
    return const Success(unit);
  }

  @override
  Future<Result<PreparedStatementMetrics>>
      getPreparedStatementsMetrics() async {
    return const Success(
      PreparedStatementMetrics(
        cacheSize: 0,
        cacheMaxSize: 100,
        cacheHits: 0,
        cacheMisses: 0,
        totalPrepares: 0,
        totalExecutions: 0,
        memoryUsageBytes: 0,
        avgExecutionsPerStmt: 0,
      ),
    );
  }

  @override
  Future<String?> detectDriver(String connectionString) async {
    return 'mock';
  }

  void dispose() {
    _connection = Connection(
      id: '',
      connectionString: '',
      createdAt: DateTime.now(),
    );
  }
}
