import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

import '../../helpers/load_env.dart';

/// Fake worker: responds to InitializeRequest only, never responds to others.
void _fakeWorkerNoResponse(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((Object? message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
    }
  });
}

/// Fake worker: sends handshake but never responds to any request.
void _fakeWorkerNeverResponds(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((Object? message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
  });
}

/// Fake worker: supports prepare/execute paths used by named-params tests.
void _fakeWorkerNamedSupport(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);
  receivePort.listen((Object? message) {
    if (message == 'shutdown') {
      receivePort.close();
      return;
    }
    if (message is InitializeRequest) {
      mainSendPort.send(InitializeResponse(message.requestId, success: true));
      return;
    }
    if (message is PrepareRequest) {
      final hasNamedPlaceholder =
          message.sql.contains('@') || message.sql.contains(':');
      mainSendPort.send(
        IntResponse(message.requestId, hasNamedPlaceholder ? 0 : 42),
      );
      return;
    }
    if (message is ExecutePreparedRequest) {
      if (message.serializedParams.isEmpty) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'missing params'),
        );
      } else {
        mainSendPort.send(
          QueryResponse(message.requestId, data: Uint8List.fromList([1])),
        );
      }
      return;
    }
    if (message is ExecuteQueryParamsRequest) {
      final hasNamedPlaceholder =
          message.sql.contains('@') || message.sql.contains(':');
      if (hasNamedPlaceholder) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'named placeholders leaked'),
        );
      } else if (message.serializedParams.isEmpty) {
        mainSendPort.send(
          QueryResponse(message.requestId, error: 'missing params'),
        );
      } else {
        mainSendPort.send(
          QueryResponse(message.requestId, data: Uint8List.fromList([2])),
        );
      }
      return;
    }
    if (message is CloseStatementRequest) {
      mainSendPort.send(BoolResponse(message.requestId, value: true));
      return;
    }
  });
}

void main() {
  loadTestEnv();
  group('AsyncError', () {
    test('should convert to ConnectionError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection failed',
        sqlState: '08001',
        nativeCode: 1,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection failed'));
      expect(odbcError.sqlState, equals('08001'));
      expect(odbcError.nativeCode, equals(1));
    });

    test('should convert to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Query failed',
        sqlState: '42000',
        nativeCode: 102,
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Query failed'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(102));
    });

    test('should convert to ValidationError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.invalidParameter,
        message: 'Invalid parameter',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ValidationError>());
      expect(odbcError.message, equals('Invalid parameter'));
    });

    test('should convert to EnvironmentNotInitializedError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.notInitialized,
        message: 'Not initialized',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<EnvironmentNotInitializedError>());
    });

    test('should convert requestTimeout to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.requestTimeout,
        message: 'Worker did not respond within 5s',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Worker did not respond within 5s'));
    });

    test('should convert workerTerminated to QueryError', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.workerTerminated,
        message: 'Connection disposed; worker shutting down',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<QueryError>());
      expect(
        odbcError.message,
        equals('Connection disposed; worker shutting down'),
      );
    });

    test('should provide readable toString', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Test error',
        sqlState: '08001',
        nativeCode: 1,
      );

      final str = asyncError.toString();

      expect(str, contains('AsyncError'));
      expect(str, contains('connectionFailed'));
      expect(str, contains('Test error'));
      expect(str, contains('SQLSTATE: 08001'));
      expect(str, contains('Native: 1'));
    });
  });

  group('AsyncNativeOdbcConnection', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection();
    });

    test('should initialize without blocking', () async {
      final stopwatch = Stopwatch()..start();
      await async.initialize();
      stopwatch.stop();

      expect(async.isInitialized, isTrue);
      // Should complete quickly even if ODBC init is slow
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('should return true when already initialized', () async {
      await async.initialize();
      expect(async.isInitialized, isTrue);

      // Second initialize should return true immediately
      final result = await async.initialize();
      expect(result, isTrue);
    });

    test('should throw AsyncError when connecting without initialization',
        () async {
      // Skip initialization
      expect(
        () => async.connect('DSN=Test'),
        throwsA(isA<AsyncError>()),
      );
    });

    test('should throw AsyncError with notInitialized code', () async {
      try {
        await async.connect('DSN=Test');
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.notInitialized));
        expect(e.message, contains('not initialized'));
      }
    });

    test(
      'should not block main thread during long operation',
      () async {
        await async.initialize();

        // Simulate UI thread responsiveness
        final uiResponder = Completer<void>();
        Timer(const Duration(milliseconds: 50), uiResponder.complete);

        // Run operation (even if it takes time)
        // Note: This will fail with invalid DSN but that's ok for the test
        try {
          await async.connect('DSN=InvalidDSNThatMightTimeout');
        } on Exception {
          // Expected - invalid DSN
        }

        // UI should have responded even if connect took time
        await expectLater(uiResponder.future, completes);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'should NOT block main thread during long query',
      () async {
        final dsn = getTestEnv('ODBC_TEST_DSN');
        if (dsn == null) return;

        await async.initialize();
        final connId = await async.connect(dsn);

        final timerCompleted = Completer<void>();
        Timer(const Duration(milliseconds: 100), timerCompleted.complete);

        final queryFuture = async.executeQueryParams(
          connId,
          "WAITFOR DELAY '00:00:05'; SELECT 1",
          [],
        );

        await expectLater(
          timerCompleted.future,
          completes,
          reason: 'Timer should complete before long query finishes',
        );
        await queryFuture;
        await async.disconnect(connId);
      },
      skip: 'Slow integration test - uses WAITFOR DELAY',
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'should execute multiple queries (all complete without deadlock)',
      () async {
        final dsn = getTestEnv('ODBC_TEST_DSN');
        if (dsn == null) return;

        await async.initialize();
        final connId1 = await async.connect(dsn);
        final connId2 = await async.connect(dsn);
        final connId3 = await async.connect(dsn);

        final stopwatch = Stopwatch()..start();
        await Future.wait([
          async.executeQueryParams(connId1, "WAITFOR DELAY '00:00:02'", []),
          async.executeQueryParams(connId2, "WAITFOR DELAY '00:00:02'", []),
          async.executeQueryParams(connId3, "WAITFOR DELAY '00:00:02'", []),
        ]);
        stopwatch.stop();

        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(10000),
          reason: 'All three 2s queries should complete without deadlock',
        );
        await async.disconnect(connId1);
        await async.disconnect(connId2);
        await async.disconnect(connId3);
      },
      skip: 'Slow integration test - multiple concurrent queries with delays',
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('should handle errors gracefully', () async {
      await async.initialize();

      // Try to get error when there is none
      final error = await async.getError();
      expect(error, isA<String>());

      // Try to disconnect with invalid connection ID
      final result = await async.disconnect(999);
      expect(result, isA<bool>());
    });

    test('should delegate streaming methods directly', () {
      // Streaming methods should be delegated, not wrapped in Isolate
      final stream1 = async.streamQuery(1, 'SELECT 1', chunkSize: 100);
      final stream2 = async.streamQueryBatched(1, 'SELECT 1', fetchSize: 100);

      // Should return Stream objects (not Future)
      expect(stream1, isA<Stream<ParsedRowBuffer>>());
      expect(stream2, isA<Stream<ParsedRowBuffer>>());
    });

    test('should call dispose on underlying connection', () {
      // Dispose should be synchronous and call through to native
      async.dispose();

      // If it didn't throw, it worked
      expect(true, isTrue);
    });

    test('should handle getStructuredError async', () async {
      await async.initialize();

      // Get structured error - may or may not be null depending on ODBC state
      final error = await async.getStructuredError();

      // Just verify it completes successfully and returns the correct type
      expect(error, isA<StructuredError?>());
    });
  });

  group('AsyncNativeOdbcConnection timeout', () {
    test(
      'should throw AsyncError with requestTimeout when worker '
      'does not respond',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(milliseconds: 50),
          isolateEntry: _fakeWorkerNoResponse,
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
        isolateEntry: _fakeWorkerNoResponse,
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
          isolateEntry: _fakeWorkerNoResponse,
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

  group('AsyncNativeOdbcConnection worker crash', () {
    test(
      'should complete pending requests with error when worker isolate dies',
      () async {
        final async = AsyncNativeOdbcConnection(
          requestTimeout: const Duration(seconds: 60),
          isolateEntry: _fakeWorkerNeverResponds,
        );

        final initFuture = async.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        async.workerIsolateForTesting?.kill();

        try {
          await initFuture;
          fail('Should have thrown AsyncError');
        } on AsyncError catch (e) {
          expect(e.code, equals(AsyncErrorCode.workerTerminated));
          expect(e.message, contains('Worker isolate'));
        }
      },
      skip: 'Isolate.kill() onDone timing is platform-dependent; '
          'dispose test covers _failAllPending path',
    );
  });

  group('BinaryProtocolParser', () {
    test(
      'should throw FormatException instead of RangeError when '
      'buffer is truncated',
      () {
        final header = Uint8List(BinaryProtocolParser.headerSize);
        ByteData.sublistView(header)
          ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
          ..setUint16(4, 1, Endian.little)
          ..setUint16(6, 0, Endian.little)
          ..setUint32(8, 0, Endian.little)
          ..setUint32(12, 1000, Endian.little);

        expect(
          () => BinaryProtocolParser.parse(header),
          throwsA(isA<FormatException>()),
        );
        try {
          BinaryProtocolParser.parse(header);
          fail('Should have thrown FormatException');
        } on FormatException catch (e) {
          expect(e.message, contains('Buffer too small for payload'));
        }
      },
    );
  });

  group('AsyncNativeOdbcConnection named parameters', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(isolateEntry: _fakeWorkerNamedSupport);
    });

    tearDown(() {
      async.dispose();
    });

    test('should prepare and execute named prepared statement', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id',
        timeoutMs: 250,
      );
      expect(stmtId, equals(42));

      final result = await async.executePreparedNamed(
        stmtId,
        {'id': 1},
        100,
        500,
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('should execute query with named parameters', () async {
      await async.initialize();

      final result = await async.executeQueryNamed(
        1,
        'SELECT * FROM users WHERE id = @id',
        {'id': 7},
      );

      expect(result, isNotNull);
      expect(result, isNotEmpty);
    });

    test('should throw invalidParameter when named param is missing', () async {
      await async.initialize();

      final stmtId = await async.prepareNamed(
        1,
        'SELECT * FROM users WHERE id = :id AND name = :name',
      );
      expect(stmtId, equals(42));

      try {
        await async.executePreparedNamed(stmtId, {'id': 1}, 0, 1000);
        fail('Should have thrown AsyncError');
      } on AsyncError catch (e) {
        expect(e.code, equals(AsyncErrorCode.invalidParameter));
        expect(e.message, contains('Missing required parameters'));
      }
    });
  });

  group('AsyncError Integration', () {
    test('should preserve all error information across isolate boundary', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'Syntax error near SELECT',
        sqlState: '42000',
        nativeCode: 156,
      );

      final odbcError = asyncError.toOdbcError();

      // Verify all information is preserved
      expect(odbcError, isA<QueryError>());
      expect(odbcError.message, equals('Syntax error near SELECT'));
      expect(odbcError.sqlState, equals('42000'));
      expect(odbcError.nativeCode, equals(156));
    });

    test('should handle error without SQLSTATE or native code', () {
      const asyncError = AsyncError(
        code: AsyncErrorCode.connectionFailed,
        message: 'Connection timeout',
      );

      final odbcError = asyncError.toOdbcError();

      expect(odbcError, isA<ConnectionError>());
      expect(odbcError.message, equals('Connection timeout'));
      expect(odbcError.sqlState, isNull);
      expect(odbcError.nativeCode, isNull);
    });
  });
}
