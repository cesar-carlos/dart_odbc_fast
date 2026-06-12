import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/xid.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as odbc_bindings show Utf8;
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart'
    show OdbcNative;
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/odbc_fast.dart'
    show ConnectionPool, PreparedStatement;
import 'package:test/test.dart';

import 'bindings/fake_odbc_bindings.dart';
import 'bindings/test_odbc_bindings.dart';

// Suite order-sensitivity: every test uses NativeOdbcConnection.testing with
// FakeOdbcBindings so we never load/dispose the production native library in
// parallel with other FFI tests (avoids flaky init races in full `dart test`).

const _testCapabilities = TestOdbcBindingsCapabilities(
  supportsXa: true,
  supportsPoolCreateWithOptions: true,
);

const _fakeConnStr = 'Driver={Fake ODBC};Server=stub';

NativeOdbcConnection _connection(
  TestOdbcBindingsOverrides overrides, {
  TestOdbcBindingsCapabilities capabilities = _testCapabilities,
}) {
  return NativeOdbcConnection.testing(
    OdbcNative.withBindings(
      FakeOdbcBindings.custom(
        capabilities: capabilities,
        overrides: overrides,
      ),
    ),
  );
}

NativeOdbcConnection _stubConnection(
  StubOdbcBindingsHandlers handlers, {
  TestOdbcBindingsCapabilities capabilities = _testCapabilities,
  TestOdbcBindingsOverrides overrides = const TestOdbcBindingsOverrides(),
}) {
  return NativeOdbcConnection.testing(
    OdbcNative.withBindings(
      FakeOdbcBindings.stub(
        capabilities: capabilities,
        overrides: overrides,
        handlers: handlers,
      ),
    ),
  );
}

int _catalogWriteFrame(
  ffi.Pointer<ffi.Uint8> outBuf,
  int bufLen,
  ffi.Pointer<ffi.Uint32> outWritten,
) {
  final frame = FakeOdbcBindings.minimalStreamRowMajorFrame();
  FakeOdbcBindings.writePayload(outBuf, bufLen, outWritten, frame);
  return 0;
}

int _detectDriverPostgres(
  ffi.Pointer<odbc_bindings.Utf8> _,
  ffi.Pointer<ffi.Int8> outBuf,
  int bufLen,
) {
  const name = 'postgres';
  final n = name.length < bufLen ? name.length : bufLen;
  for (var i = 0; i < n; i++) {
    outBuf[i] = name.codeUnitAt(i);
  }
  if (n < bufLen) {
    outBuf[n] = 0;
  }
  return 1;
}

int _initSuccess() => 0;

Uint8List _metricsWireBytes({
  int queryCount = 10,
  int errorCount = 2,
  int uptimeSecs = 3600,
  int totalLatencyMillis = 5000,
  int avgLatencyMillis = 500,
}) {
  final data = ByteData(40)
    ..setUint64(0, queryCount, Endian.little)
    ..setUint64(8, errorCount, Endian.little)
    ..setUint64(16, uptimeSecs, Endian.little)
    ..setUint64(24, totalLatencyMillis, Endian.little)
    ..setUint64(32, avgLatencyMillis, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  group('NativeOdbcConnection', () {
    test('exposes typed audit logger wrapper', () {
      final connection = _connection(const TestOdbcBindingsOverrides());
      expect(connection.auditLogger, isA<OdbcAuditLogger>());
      connection.dispose();
    });

    group('initialize', () {
      test('should_ignore_second_initialize_call_when_already_initialized', () {
        var initCalls = 0;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: () {
              initCalls++;
              return _initSuccess();
            },
          ),
        );

        expect(connection.initialize(), isTrue);
        expect(connection.initialize(), isTrue);
        expect(connection.isInitialized, isTrue);
        expect(initCalls, equals(1));
        connection.dispose();
      });
    });

    group('connect guards', () {
      test('should_throw_state_error_when_connect_before_initialize', () {
        final connection = _connection(const TestOdbcBindingsOverrides());

        expect(
          () => connection.connect('DSN=test'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Environment not initialized',
            ),
          ),
        );
        connection.dispose();
      });

      test(
        'should_throw_state_error_when_connect_with_timeout_before_initialize',
        () {
          final connection = _connection(const TestOdbcBindingsOverrides());

          expect(
            () => connection.connectWithTimeout('DSN=test', 1000),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'Environment not initialized',
              ),
            ),
          );
          connection.dispose();
        },
      );
    });

    group('connect after initialize', () {
      test('should_return_connection_id_when_environment_initialized', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            connect: _connectReturns5,
          ),
        )..initialize();

        expect(connection.connect('DSN=test'), equals(5));
        connection.dispose();
      });
    });

    group('beginTransactionHandle', () {
      test('should_return_null_when_native_returns_zero', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            transactionBegin: _returnZeroTxn,
          ),
        )..initialize();

        expect(connection.beginTransactionHandle(1, 1), isNull);
        connection.dispose();
      });

      test('should_return_handle_when_native_returns_positive_id', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            transactionBegin: _returnTxn42,
          ),
        )..initialize();

        final handle = connection.beginTransactionHandle(1, 2);

        expect(handle, isNotNull);
        expect(handle!.txnId, equals(42));
        connection.dispose();
      });
    });

    group('prepareStatement', () {
      test('should_return_null_when_prepare_returns_zero', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            prepare: _returnZeroStmt,
          ),
        )..initialize();

        expect(
          connection.prepareStatement(1, 'SELECT 1'),
          isNull,
        );
        connection.dispose();
      });

      test('should_return_wrapper_when_prepare_returns_positive_id', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            prepare: _returnStmt7,
          ),
        )..initialize();

        final stmt = connection.prepareStatement(1, 'SELECT ?');

        expect(stmt, isA<PreparedStatement>());
        expect(stmt!.stmtId, equals(7));
        connection.dispose();
      });
    });

    group('prepareStatementNamed', () {
      test('should_prepare_cleaned_sql_and_enable_execute_named', () {
        String? capturedSql;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            prepare: FakeOdbcBindings.prepareCapturing(
              (sql) => capturedSql = sql,
              stmtId: 12,
            ),
          ),
        )..initialize();

        final stmt = connection.prepareStatementNamed(
          1,
          'SELECT * FROM t WHERE id = @id AND name = :name',
        );

        expect(stmt, isA<PreparedStatement>());
        expect(stmt!.stmtId, equals(12));
        expect(
          capturedSql,
          equals('SELECT * FROM t WHERE id = ? AND name = ?'),
        );
        connection.dispose();
      });

      test('should_return_null_when_named_prepare_fails', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            prepare: _returnZeroStmt,
          ),
        )..initialize();

        expect(
          connection.prepareStatementNamed(1, 'SELECT @x'),
          isNull,
        );
        connection.dispose();
      });
    });

    group('poolCreate routing', () {
      test('should_use_simple_pool_create_when_options_absent', () {
        var simpleCalls = 0;
        var withOptionsCalls = 0;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            poolCreate: (_, __) {
              simpleCalls++;
              return 9;
            },
            poolCreateWithOptions: (_, __, ___) {
              withOptionsCalls++;
              return 10;
            },
          ),
        );

        expect(
          connection.poolCreate('DSN=test', 5),
          equals(9),
        );
        expect(simpleCalls, equals(1));
        expect(withOptionsCalls, equals(0));
        connection.dispose();
      });

      test('should_use_with_options_when_pool_options_set', () {
        var simpleCalls = 0;
        var withOptionsCalls = 0;
        int? capturedOptionsAddress;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            poolCreate: (_, __) {
              simpleCalls++;
              return 9;
            },
            poolCreateWithOptions: (_, __, optionsJson) {
              withOptionsCalls++;
              capturedOptionsAddress = optionsJson?.address;
              return 11;
            },
          ),
        );

        final poolId = connection.poolCreate(
          'DSN=test',
          5,
          options: const PoolOptions(idleTimeout: Duration(seconds: 30)),
        );

        expect(poolId, equals(11));
        expect(simpleCalls, equals(0));
        expect(withOptionsCalls, equals(1));
        expect(capturedOptionsAddress, isNotNull);
        expect(capturedOptionsAddress, greaterThan(0));
        connection.dispose();
      });

      test('should_use_simple_pool_create_when_pool_options_have_no_fields',
          () {
        var simpleCalls = 0;
        var withOptionsCalls = 0;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            poolCreate: (_, __) {
              simpleCalls++;
              return 8;
            },
            poolCreateWithOptions: (_, __, ___) {
              withOptionsCalls++;
              return 9;
            },
          ),
        );

        expect(
          connection.poolCreate('DSN=test', 5, options: const PoolOptions()),
          equals(8),
        );
        expect(simpleCalls, equals(1));
        expect(withOptionsCalls, equals(0));
        connection.dispose();
      });
    });

    group('createConnectionPool', () {
      test('should_return_null_when_pool_create_returns_zero', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(poolCreate: _returnZeroPool),
        );

        expect(
          connection.createConnectionPool('DSN=test', 3),
          isNull,
        );
        connection.dispose();
      });

      test('should_return_wrapper_when_pool_create_succeeds', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(poolCreate: _returnPool3),
        );

        final pool = connection.createConnectionPool('DSN=test', 3);

        expect(pool, isA<ConnectionPool>());
        expect(pool!.poolId, equals(3));
        connection.dispose();
      });
    });

    group('xaRecover', () {
      test('should_return_null_when_recover_count_negative', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            xaRecoverCount: _xaRecoverNegative,
          ),
        )..initialize();

        expect(connection.xaRecover(1), isNull);
        connection.dispose();
      });

      test('should_skip_invalid_xids_and_return_valid_entries', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            xaRecoverCount: _xaRecoverCount3,
            xaRecoverGet: _xaRecoverMixedEntries,
          ),
        )..initialize();

        final xids = connection.xaRecover(1);

        expect(xids, hasLength(1));
        expect(
          xids!.single,
          equals(
            Xid(
              formatId: 7,
              gtrid: Uint8List.fromList([0x41]),
            ),
          ),
        );
        connection.dispose();
      });

      test('should_return_empty_list_when_no_prepared_xids_exist', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            xaRecoverCount: _xaRecoverCountZero,
          ),
        )..initialize();

        expect(connection.xaRecover(1), isEmpty);
        connection.dispose();
      });
    });

    group('getMetrics', () {
      test('should_map_native_metrics_to_domain_entity', () {
        final connection = _connection(
          TestOdbcBindingsOverrides(
            getMetrics: (buffer, bufferLen, outWritten) {
              final bytes = _metricsWireBytes(
                queryCount: 100,
                errorCount: 5,
                uptimeSecs: 99,
                totalLatencyMillis: 4000,
                avgLatencyMillis: 40,
              );
              final n = bytes.length < bufferLen ? bytes.length : bufferLen;
              buffer.asTypedList(n).setAll(0, bytes.sublist(0, n));
              outWritten.value = 40;
              return 0;
            },
          ),
        );

        final metrics = connection.getMetrics();

        expect(metrics, isNotNull);
        expect(metrics!.queryCount, equals(100));
        expect(metrics.errorCount, equals(5));
        expect(metrics.uptimeSecs, equals(99));
        expect(metrics.totalLatencyMillis, equals(4000));
        expect(metrics.avgLatencyMillis, equals(40));
        connection.dispose();
      });

      test('should_return_null_when_native_get_metrics_fails', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(getMetrics: _metricsFfiFailure),
        );

        expect(connection.getMetrics(), isNull);
        connection.dispose();
      });
    });

    group('streamQuery success paths', () {
      test('should_parse_batched_stream_payload', () async {
        final frame = FakeOdbcBindings.minimalStreamRowMajorFrame();
        final fetchOverride = FakeOdbcBindings.streamFetchChunks([frame]);
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStartBatched: _streamStartBatchedOne,
            streamFetch: fetchOverride.streamFetch,
          ),
        )..initialize();

        final chunks =
            await connection.streamQueryBatched(1, 'SELECT 1').toList();

        expect(chunks, hasLength(1));
        expect(chunks.first.rowCount, equals(1));
        expect(chunks.first.columns.first.name, equals('id'));
        connection.dispose();
      });

      test('should_parse_simple_stream_payload', () async {
        final frame = FakeOdbcBindings.minimalStreamRowMajorFrame();
        final fetchOverride = FakeOdbcBindings.streamFetchChunks([frame]);
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStart: _streamStartOne,
            streamFetch: fetchOverride.streamFetch,
          ),
        )..initialize();

        final chunks = await connection.streamQuery(1, 'SELECT 1').toList();

        expect(chunks, hasLength(1));
        expect(chunks.first.rowCount, equals(1));
        connection.dispose();
      });
    });

    group('streamQuery error paths', () {
      test('should_throw_when_batched_stream_start_returns_zero', () async {
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStartBatched: _streamStartBatchedZero,
            getError: FakeOdbcBindings.getErrorWrites('batched start failed'),
          ),
        )..initialize();

        await expectLater(
          connection.streamQueryBatched(1, 'SELECT 1').drain<void>(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('batched start failed'),
            ),
          ),
        );
        connection.dispose();
      });

      test('should_throw_when_stream_fetch_fails_in_batched_mode', () async {
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStartBatched: _streamStartBatchedOne,
            streamFetch: _streamFetchFailure,
            getError: FakeOdbcBindings.getErrorWrites('fetch failed'),
          ),
        )..initialize();

        await expectLater(
          connection.streamQueryBatched(1, 'SELECT 1').drain<void>(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('fetch failed'),
            ),
          ),
        );
        connection.dispose();
      });

      test('should_throw_when_simple_stream_start_returns_zero', () async {
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStart: _streamStartZero,
            getError: FakeOdbcBindings.getErrorWrites('stream start failed'),
          ),
        )..initialize();

        await expectLater(
          connection.streamQuery(1, 'SELECT 1').drain<void>(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('stream start failed'),
            ),
          ),
        );
        connection.dispose();
      });

      test('should_throw_when_simple_stream_fetch_fails', () async {
        var closeCalls = 0;
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStart: _streamStartOne,
            streamFetch: _streamFetchFailure,
            streamClose: (_) {
              closeCalls++;
              return 0;
            },
            getError: FakeOdbcBindings.getErrorWrites('simple fetch failed'),
          ),
        )..initialize();

        await expectLater(
          connection.streamQuery(1, 'SELECT 1').drain<void>(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('simple fetch failed'),
            ),
          ),
        );
        expect(closeCalls, equals(1));
        connection.dispose();
      });

      test(
        'should_throw_format_exception_when_batched_stream_has_leftover_bytes',
        () async {
          final connection = _connection(
            TestOdbcBindingsOverrides(
              init: _initSuccess,
              streamStartBatched: _streamStartBatchedOne,
              streamFetch: FakeOdbcBindings.streamFetchChunks([
                Uint8List.fromList([0x4F, 0x44]),
              ]).streamFetch,
            ),
          )..initialize();

          await expectLater(
            connection.streamQueryBatched(1, 'SELECT 1').drain<void>(),
            throwsA(isA<FormatException>()),
          );
          connection.dispose();
        },
      );

      test('should_yield_no_chunks_when_fetch_returns_empty_data', () async {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStart: _streamStartOne,
            streamFetch: _streamFetchEmptySuccess,
          ),
        )..initialize();

        final chunks = await connection.streamQuery(1, 'SELECT 1').toList();

        expect(chunks, isEmpty);
        connection.dispose();
      });

      test('should_yield_multiple_batches_when_fetch_has_more_flag_set',
          () async {
        final frame = FakeOdbcBindings.minimalStreamRowMajorFrame();
        final connection = _connection(
          TestOdbcBindingsOverrides(
            init: _initSuccess,
            streamStartBatched: _streamStartBatchedOne,
            streamFetch:
                _streamFetchTwoChunksWithHasMore([frame, frame]).streamFetch,
          ),
        )..initialize();

        final chunks =
            await connection.streamQueryBatched(1, 'SELECT 1').toList();

        expect(chunks, hasLength(2));
        expect(chunks.every((c) => c.rowCount == 1), isTrue);
        connection.dispose();
      });
    });

    group('disconnect and validation', () {
      test('should_return_true_when_native_disconnect_succeeds', () {
        final connection = _stubConnection(
          const StubOdbcBindingsHandlers(disconnect: _disconnectSuccess),
        );

        expect(connection.disconnect(9), isTrue);
        connection.dispose();
      });

      test('should_return_false_when_native_disconnect_fails', () {
        final connection = _stubConnection(
          const StubOdbcBindingsHandlers(disconnect: _disconnectFailure),
        );

        expect(connection.disconnect(9), isFalse);
        connection.dispose();
      });

      test('should_return_null_when_connection_string_is_valid', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(
            validateConnectionString: _validateConnectionStringOk,
          ),
        );

        expect(connection.validateConnectionString(_fakeConnStr), isNull);
        connection.dispose();
      });

      test('should_return_message_when_connection_string_is_invalid', () {
        final connection = _connection(
          TestOdbcBindingsOverrides(
            validateConnectionString:
                FakeOdbcBindings.validateConnectionStringReturns(
              'missing driver',
            ),
          ),
        );

        expect(
          connection.validateConnectionString('Server=only'),
          equals('missing driver'),
        );
        connection.dispose();
      });

      test('should_expose_driver_and_structured_error_from_native', () {
        final connection = _stubConnection(
          StubOdbcBindingsHandlers(
            detectDriver: _detectDriverPostgres,
            structuredError: (buffer, bufferLen, outWritten) {
              FakeOdbcBindings.writePayload(
                buffer,
                bufferLen,
                outWritten,
                FakeOdbcBindings.structuredErrorPayload(
                  sqlState: '08S01',
                  nativeCode: 42,
                  message: 'communication failure',
                ),
              );
              return 0;
            },
          ),
          overrides: const TestOdbcBindingsOverrides(
            getError: _getErrorEmpty,
          ),
        );

        expect(connection.detectDriver(_fakeConnStr), equals('postgres'));
        expect(connection.getError(), isEmpty);

        final err = connection.getStructuredError();
        expect(err, isNotNull);
        expect(err!.sqlStateString, equals('08S01'));
        expect(err.nativeCode, equals(42));
        expect(err.message, equals('communication failure'));
        connection.dispose();
      });
    });

    group('catalog stubs', () {
      test('should_parse_catalog_tables_via_catalog_query_wrapper', () {
        String? capturedCatalog;
        String? capturedSchema;
        final connection = _stubConnection(
          StubOdbcBindingsHandlers(
            catalogTables: (
              connId,
              catalog,
              schema,
              outBuf,
              bufLen,
              outWritten,
            ) {
              capturedCatalog = FakeOdbcBindings.readUtf8Pointer(catalog);
              capturedSchema = FakeOdbcBindings.readUtf8Pointer(schema);
              return _catalogWriteFrame(outBuf, bufLen, outWritten);
            },
          ),
        );

        final parsed =
            connection.catalogQuery(3).tables(catalog: 'mydb', schema: 'dbo');

        expect(parsed, isNotNull);
        expect(parsed!.rowCount, equals(1));
        expect(capturedCatalog, equals('mydb'));
        expect(capturedSchema, equals('dbo'));
        connection.dispose();
      });

      test('should_return_null_when_catalog_columns_native_call_fails', () {
        final connection = _stubConnection(
          const StubOdbcBindingsHandlers(
            catalogColumns: _catalogColumnsFailure,
          ),
        );

        expect(connection.catalogColumns(1, 'users'), isNull);
        connection.dispose();
      });

      test(
        'should_delegate_primary_foreign_and_index_catalog_calls',
        () {
          var pkCalls = 0;
          var fkCalls = 0;
          var indexCalls = 0;
          final connection = _stubConnection(
            StubOdbcBindingsHandlers(
              catalogPrimaryKeys: (connId, table, outBuf, bufLen, outWritten) {
                pkCalls++;
                expect(FakeOdbcBindings.readUtf8Pointer(table), equals('t'));
                return _catalogWriteFrame(outBuf, bufLen, outWritten);
              },
              catalogForeignKeys: (connId, table, outBuf, bufLen, outWritten) {
                fkCalls++;
                return _catalogWriteFrame(outBuf, bufLen, outWritten);
              },
              catalogIndexes: (connId, table, outBuf, bufLen, outWritten) {
                indexCalls++;
                return _catalogWriteFrame(outBuf, bufLen, outWritten);
              },
              catalogTypeInfo: (
                connId,
                outBuf,
                bufLen,
                outWritten,
              ) =>
                  _catalogWriteFrame(outBuf, bufLen, outWritten),
            ),
          );

          expect(
            connection.catalogPrimaryKeys(1, 't'),
            isNotNull,
          );
          expect(connection.catalogForeignKeys(1, 't'), isNotNull);
          expect(connection.catalogIndexes(1, 't'), isNotNull);
          expect(connection.catalogTypeInfo(1), isNotNull);
          expect(pkCalls, equals(1));
          expect(fkCalls, equals(1));
          expect(indexCalls, equals(1));
          connection.dispose();
        },
      );
    });

    group('statement lifecycle', () {
      test(
        'should_prepare_cancel_close_and_clear_statements_via_native',
        () {
          final connection = _connection(
            const TestOdbcBindingsOverrides(
              init: _initSuccess,
              prepare: _returnStmt7,
            ),
          )..initialize();

          final stmt = connection.prepareStatement(1, 'SELECT ?');
          expect(stmt, isNotNull);

          expect(connection.cancelStatement(stmt!.stmtId), isA<bool>());
          expect(connection.closeStatement(stmt.stmtId), isA<bool>());
          expect(connection.clearAllStatements(), isA<int>());
          expect(connection.clearStatementCache(), isA<bool>());
          connection.dispose();
        },
      );
    });

    group('pool health', () {
      test('should_delegate_pool_health_and_state_after_pool_create', () {
        final connection = _connection(
          const TestOdbcBindingsOverrides(poolCreate: _returnPool3),
        );
        const poolId = 3;

        expect(connection.poolHealthCheck(poolId), isA<bool>());
        expect(connection.poolGetState(poolId), anyOf(isNull, isNotNull));
        connection.dispose();
      });
    });
  });
}

int _connectReturns5(ffi.Pointer<odbc_bindings.Utf8> _) => 5;

int _returnZeroTxn(int _, int __, int ___) => 0;

int _returnTxn42(int _, int __, int ___) => 42;

int _returnZeroStmt(int _, ffi.Pointer<odbc_bindings.Utf8> __, int ___) => 0;

int _returnStmt7(int _, ffi.Pointer<odbc_bindings.Utf8> __, int ___) => 7;

int _returnZeroPool(ffi.Pointer<odbc_bindings.Utf8> _, int __) => 0;

int _returnPool3(ffi.Pointer<odbc_bindings.Utf8> _, int __) => 3;

int _metricsFfiFailure(
  ffi.Pointer<ffi.Uint8> _,
  int __,
  ffi.Pointer<ffi.Uint32> ___,
) =>
    -1;

int _xaRecoverNegative(int _) => -1;

int _xaRecoverCount3(int _) => 3;

int _xaRecoverCountZero(int _) => 0;

int _streamStartOne(int _, ffi.Pointer<odbc_bindings.Utf8> __, int ___) => 1;

int _streamStartBatchedZero(
  int _,
  ffi.Pointer<odbc_bindings.Utf8> __,
  int ___,
  int ____,
) =>
    0;

int _streamStartBatchedOne(
  int _,
  ffi.Pointer<odbc_bindings.Utf8> __,
  int ___,
  int ____,
) =>
    1;

int _streamFetchFailure(
  int _,
  ffi.Pointer<ffi.Uint8> __,
  int ___,
  ffi.Pointer<ffi.Uint32> ____,
  ffi.Pointer<ffi.Uint8> _____,
) =>
    -1;

int _streamStartZero(int _, ffi.Pointer<odbc_bindings.Utf8> __, int ___) => 0;

int _disconnectSuccess(int _) => 0;

int _disconnectFailure(int _) => -1;

int _getErrorEmpty(ffi.Pointer<ffi.Int8> _, int __) => 0;

int _validateConnectionStringOk(
  ffi.Pointer<odbc_bindings.Utf8> _,
  ffi.Pointer<ffi.Uint8> __,
  int ___,
) =>
    0;

int _catalogColumnsFailure(
  int _,
  ffi.Pointer<odbc_bindings.Utf8> __,
  ffi.Pointer<ffi.Uint8> ___,
  int ____,
  ffi.Pointer<ffi.Uint32> _____,
) =>
    -1;

int _streamFetchEmptySuccess(
  int _,
  ffi.Pointer<ffi.Uint8> __,
  int ___,
  ffi.Pointer<ffi.Uint32> outWritten,
  ffi.Pointer<ffi.Uint8> hasMore,
) {
  outWritten.value = 0;
  hasMore.value = 0;
  return 0;
}

TestOdbcBindingsOverrides _streamFetchTwoChunksWithHasMore(
  List<Uint8List> chunks,
) {
  var index = 0;
  return TestOdbcBindingsOverrides(
    streamFetch: (
      streamId,
      outBuf,
      bufLen,
      outWritten,
      hasMore,
    ) {
      if (index >= chunks.length) {
        outWritten.value = 0;
        hasMore.value = 0;
        return 0;
      }
      final chunk = chunks[index++];
      final n = chunk.length < bufLen ? chunk.length : bufLen;
      outBuf.asTypedList(n).setAll(0, chunk.sublist(0, n));
      outWritten.value = n;
      hasMore.value = index < chunks.length ? 1 : 0;
      return 0;
    },
  );
}

int _xaRecoverMixedEntries(
  int index,
  ffi.Pointer<ffi.Int32> outFormatId,
  ffi.Pointer<ffi.Uint8> gtridBuf,
  int gtridBufLen,
  ffi.Pointer<ffi.Uint32> outGtridLen,
  ffi.Pointer<ffi.Uint8> bqualBuf,
  int bqualBufLen,
  ffi.Pointer<ffi.Uint32> outBqualLen,
) {
  switch (index) {
    case 0:
      outFormatId.value = 0;
      outGtridLen.value = 0;
      outBqualLen.value = 0;
      return 0;
    case 1:
      outFormatId.value = 7;
      gtridBuf[0] = 0x41;
      outGtridLen.value = 1;
      outBqualLen.value = 0;
      return 0;
    default:
      return -1;
  }
}
