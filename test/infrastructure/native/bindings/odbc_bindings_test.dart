import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' hide Utf8;
import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as odbc_bindings;
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';
import 'test_odbc_bindings.dart';

void main() {
  group('OdbcBindings capability getters', () {
    test('should_expose_audit_api_when_production_library_has_quartet', () {
      final bindings = FakeOdbcBindings.production();

      expect(bindings.supportsAuditApi, isA<bool>());
    });

    test('should_report_audit_api_absent_when_legacy_minimal_profile', () {
      final bindings = FakeOdbcBindings.legacyMinimal();

      expect(bindings.supportsAuditApi, isFalse);
      expect(bindings.supportsAsyncExecuteApi, isFalse);
      expect(bindings.supportsDriverCapabilitiesApi, isFalse);
    });

    test('should_require_full_async_quintet_for_execute_api', () {
      final asyncOnly = FakeOdbcBindings.asyncOnly();
      final legacy = FakeOdbcBindings.legacyMinimal();

      expect(asyncOnly.supportsAsyncExecuteApi, isTrue);
      expect(asyncOnly.supportsAsyncExecuteParamsApi, isFalse);
      expect(legacy.supportsAsyncExecuteApi, isFalse);
    });

    test('should_gate_transaction_v2_and_v3_on_symbol_presence', () {
      final legacy = FakeOdbcBindings.legacyMinimal();
      final production = FakeOdbcBindings.production();

      expect(legacy.supportsTransactionAccessMode, isFalse);
      expect(legacy.supportsTransactionLockTimeout, isFalse);
      expect(production.supportsTransactionAccessMode, isA<bool>());
      expect(production.supportsTransactionLockTimeout, isA<bool>());
    });
  });

  group('OdbcBindings degradation and error contracts', () {
    test('should_return_minus_one_for_driver_capabilities_when_api_absent', () {
      final bindings = FakeOdbcBindings.legacyMinimal();
      final connStr = 'DSN=test'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final buffer = calloc<ffi.Uint8>(16);
      final outWritten = calloc<ffi.Uint32>();

      try {
        final code = bindings.odbc_get_driver_capabilities(
          connStr,
          buffer,
          16,
          outWritten,
        );

        expect(code, equals(-1));
      } finally {
        calloc
          ..free(connStr)
          ..free(buffer)
          ..free(outWritten);
      }
    });

    test('should_return_minus_one_for_audit_ffis_when_api_absent', () {
      final bindings = FakeOdbcBindings.legacyMinimal();
      final buffer = calloc<ffi.Uint8>(8);
      final outWritten = calloc<ffi.Uint32>();

      try {
        expect(bindings.odbc_audit_enable(1), equals(-1));
        expect(
          bindings.odbc_audit_get_events(buffer, 8, outWritten, 0),
          equals(-1),
        );
        expect(bindings.odbc_audit_clear(), equals(-1));
        expect(
          bindings.odbc_audit_get_status(buffer, 8, outWritten),
          equals(-1),
        );
      } finally {
        calloc
          ..free(buffer)
          ..free(outWritten);
      }
    });

    test('should_return_null_for_async_execute_when_api_absent', () {
      final bindings = FakeOdbcBindings.legacyMinimal();
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(bindings.odbc_execute_async(1, sql), isNull);
      } finally {
        calloc.free(sql);
      }
    });

    test('should_throw_state_error_for_multi_params_when_symbol_absent', () {
      final bindings = FakeOdbcBindings.legacyMinimal();
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(8);
      final outWritten = calloc<ffi.Uint32>();

      try {
        expect(
          () => bindings.odbc_exec_query_multi_params(
            1,
            sql,
            ffi.nullptr,
            0,
            outBuf,
            8,
            outWritten,
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        calloc
          ..free(sql)
          ..free(outBuf)
          ..free(outWritten);
      }
    });

    test('should_throw_unsupported_error_for_xa_start_when_api_absent', () {
      final bindings = FakeOdbcBindings.legacyMinimal();
      final gtrid = calloc<ffi.Uint8>();
      final bqual = calloc<ffi.Uint8>();

      try {
        expect(
          () => bindings.odbc_xa_start(1, 0, gtrid, 1, bqual, 1),
          throwsA(isA<UnsupportedError>()),
        );
      } finally {
        calloc
          ..free(gtrid)
          ..free(bqual);
      }
    });

    test('should_fallback_connect_with_timeout_to_connect_when_symbol_absent',
        () {
      var connectCalls = 0;
      final bindings = FakeOdbcBindings.custom(
        capabilities: const TestOdbcBindingsCapabilities(
          hasConnectWithTimeoutSymbol: false,
        ),
        overrides: TestOdbcBindingsOverrides(
          connect: (_) {
            connectCalls++;
            return 7;
          },
        ),
      );
      final connStr = 'DSN=x'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        final id = bindings.odbc_connect_with_timeout(connStr, 5000);

        expect(id, equals(7));
        expect(connectCalls, equals(1));
      } finally {
        calloc.free(connStr);
      }
    });

    test('should_fallback_transaction_begin_v2_to_v1_when_v2_absent', () {
      var v1Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsTransactionAccessMode: false,
        ),
        overrides: TestOdbcBindingsOverrides(
          transactionBegin: (connId, isolation, dialect) {
            v1Calls++;
            return 11;
          },
        ),
      );

      final txnId = bindings.odbc_transaction_begin_v2(1, 2, 0, 1);

      expect(txnId, equals(11));
      expect(v1Calls, equals(1));
    });

    test('should_return_null_for_stream_multi_batched_when_stub_forces_absent',
        () {
      final bindings = FakeOdbcBindings.stub(
        handlers: const StubOdbcBindingsHandlers(
          forceSupportsMultiResultStream: false,
        ),
      );
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(bindings.odbc_stream_multi_start_batched(1, sql, 1024), isNull);
      } finally {
        calloc.free(sql);
      }
    });

    test(
        'should_return_stream_id_for_stream_multi_batched_'
        'when_stub_forces_present', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          forceSupportsMultiResultStream: true,
          streamMultiStartBatched: (_, __, ___) => 55,
        ),
      );
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(
          bindings.odbc_stream_multi_start_batched(1, sql, 1024),
          equals(55),
        );
      } finally {
        calloc.free(sql);
      }
    });

    test('should_route_stream_multi_batched_options_when_encoding_requested',
        () {
      int? capturedEncoding;
      final bindings = FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          forceSupportsMultiResultStream: true,
          forceSupportsMultiResultStreamEncodingOptions: true,
          streamMultiStartBatchedOptions: (_, __, ___, ____, encoding) {
            capturedEncoding = encoding;
            return 66;
          },
        ),
      );
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(
          bindings.odbc_stream_multi_start_batched_options(
            1,
            sql,
            1000,
            1024,
            1,
          ),
          equals(66),
        );
        expect(capturedEncoding, equals(1));
      } finally {
        calloc.free(sql);
      }
    });

    test(
        'should_return_null_for_stream_multi_batched_options_'
        'when_stub_forces_absent', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: const StubOdbcBindingsHandlers(
          forceSupportsMultiResultStreamEncodingOptions: false,
        ),
      );
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(
          bindings.odbc_stream_multi_start_batched_options(
            1,
            sql,
            1000,
            1024,
            1,
          ),
          isNull,
        );
      } finally {
        calloc.free(sql);
      }
    });

    test(
        'should_return_minus_one_for_structured_error_for_connection_'
        'when_absent', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: const StubOdbcBindingsHandlers(
          forceSupportsStructuredErrorForConnection: false,
        ),
      );
      final buffer = calloc<ffi.Uint8>(16);
      final outWritten = calloc<ffi.Uint32>();

      try {
        expect(
          bindings.odbc_get_structured_error_for_connection(
            1,
            buffer,
            16,
            outWritten,
          ),
          isNull,
        );
      } finally {
        calloc
          ..free(buffer)
          ..free(outWritten);
      }
    });

    test('should_return_disconnect_code_from_stub_handler', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          disconnect: (connId) {
            expect(connId, equals(5));
            return 0;
          },
        ),
      );

      expect(bindings.odbc_disconnect(5), equals(0));
    });

    test('should_return_catalog_foreign_keys_payload_from_stub_handler', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          catalogForeignKeys: (_, table, outBuf, bufLen, outWritten) {
            expect(
              FakeOdbcBindings.readUtf8Pointer(table),
              equals('child'),
            );
            FakeOdbcBindings.writePayload(
              outBuf,
              bufLen,
              outWritten,
              Uint8List.fromList([0xAB]),
            );
            return 0;
          },
        ),
      );
      final table = 'child'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(8);
      final outWritten = calloc<ffi.Uint32>();

      try {
        final code = bindings.odbc_catalog_foreign_keys(
          1,
          table,
          outBuf,
          8,
          outWritten,
        );

        expect(code, equals(0));
        expect(outWritten.value, equals(1));
        expect(outBuf[0], equals(0xAB));
      } finally {
        calloc
          ..free(table)
          ..free(outBuf)
          ..free(outWritten);
      }
    });

    test('should_forward_stream_start_and_fetch_to_stub_overrides', () {
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          streamStart: (connId, sql, chunkSize) {
            expect(connId, equals(2));
            expect(FakeOdbcBindings.readUtf8Pointer(sql), equals('SELECT 1'));
            expect(chunkSize, equals(512));
            return 9;
          },
          streamFetch: (streamId, outBuf, bufLen, outWritten, hasMore) {
            expect(streamId, equals(9));
            FakeOdbcBindings.writePayload(
              outBuf,
              bufLen,
              outWritten,
              Uint8List.fromList([0x01]),
            );
            hasMore.value = 1;
            return 0;
          },
        ),
      );
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(8);
      final outWritten = calloc<ffi.Uint32>();
      final hasMore = calloc<ffi.Uint8>();

      try {
        expect(bindings.odbc_stream_start(2, sql, 512), equals(9));
        expect(
          bindings.odbc_stream_fetch(9, outBuf, 8, outWritten, hasMore),
          equals(0),
        );
        expect(outWritten.value, equals(1));
        expect(hasMore.value, equals(1));
      } finally {
        calloc
          ..free(sql)
          ..free(outBuf)
          ..free(outWritten)
          ..free(hasMore);
      }
    });

    test('should_forward_pool_create_and_prepare_to_stub_overrides', () {
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          poolCreate: (connStr, maxSize) {
            expect(FakeOdbcBindings.readUtf8Pointer(connStr), equals('DSN=p'));
            expect(maxSize, equals(2));
            return 4;
          },
          prepare: FakeOdbcBindings.prepareCapturing(
            (sql) => expect(sql, equals('INSERT INTO t VALUES (?)')),
            stmtId: 12,
          ),
        ),
      );
      final connStr = 'DSN=p'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final sql =
          'INSERT INTO t VALUES (?)'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(bindings.odbc_pool_create(connStr, 2), equals(4));
        expect(bindings.odbc_prepare(1, sql, 0), equals(12));
      } finally {
        calloc
          ..free(connStr)
          ..free(sql);
      }
    });

    test('should_forward_detect_driver_to_stub_handler', () {
      final bindings = FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          detectDriver: (_, outBuf, bufLen) {
            final bytes = 'postgres'.codeUnits;
            final n = bytes.length < bufLen ? bytes.length : bufLen;
            for (var i = 0; i < n; i++) {
              outBuf[i] = bytes[i];
            }
            return 1;
          },
        ),
      );
      final connStr = 'DSN=x'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Int8>(16);

      try {
        expect(bindings.odbc_detect_driver(connStr, outBuf, 16), equals(1));
        expect(outBuf[0], equals('p'.codeUnitAt(0)));
      } finally {
        calloc
          ..free(connStr)
          ..free(outBuf);
      }
    });

    test('should_throw_unsupported_error_for_xa_recover_count_when_api_absent',
        () {
      final bindings = FakeOdbcBindings.legacyMinimal();

      expect(
        () => bindings.odbc_xa_recover_count(1),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should_invoke_transaction_savepoint_and_stream_ffis_on_production',
        () {
      final bindings = FakeOdbcBindings.production();
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final sp = 'sp1'.toNativeUtf8().cast<odbc_bindings.Utf8>();

      try {
        expect(bindings.odbc_transaction_commit(0), isA<int>());
        expect(bindings.odbc_transaction_rollback(0), isA<int>());
        expect(bindings.odbc_savepoint_create(0, sp), isA<int>());
        expect(bindings.odbc_savepoint_rollback(0, sp), isA<int>());
        expect(bindings.odbc_savepoint_release(0, sp), isA<int>());
        expect(bindings.odbc_stream_start(0, sql, 1024), isA<int>());
        expect(
          bindings.odbc_stream_start_batched(0, sql, 100, 1024),
          isA<int>(),
        );
        expect(bindings.odbc_stream_cancel(0), isA<int>());
        expect(bindings.odbc_stream_close(0), isA<int>());
      } finally {
        calloc
          ..free(sql)
          ..free(sp);
      }
    });

    test('should_invoke_catalog_exec_and_cache_ffis_on_production', () {
      final bindings = FakeOdbcBindings.production();
      final sql = 't'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final empty = ''.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(64);
      final outWritten = calloc<ffi.Uint32>();
      final params = calloc<ffi.Uint8>();

      try {
        expect(
          bindings.odbc_catalog_tables(0, empty, empty, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_catalog_columns(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_catalog_type_info(0, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_catalog_primary_keys(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_catalog_foreign_keys(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_catalog_indexes(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_exec_query(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(
          bindings.odbc_exec_query_params(
            0,
            sql,
            params,
            0,
            outBuf,
            64,
            outWritten,
          ),
          isA<int>(),
        );
        expect(
          bindings.odbc_exec_query_multi(0, sql, outBuf, 64, outWritten),
          isA<int>(),
        );
        expect(bindings.odbc_clear_statement_cache(), isA<int>());
        expect(
          bindings.odbc_get_cache_metrics(outBuf, 64, outWritten),
          isA<int>(),
        );
      } finally {
        calloc
          ..free(sql)
          ..free(empty)
          ..free(outBuf)
          ..free(outWritten)
          ..free(params);
      }
    });

    test('should_invoke_pool_metadata_and_version_ffis_on_production', () {
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          poolCreate: (_, __) => 1,
          poolGetConnection: (_) => 2,
          poolReleaseConnection: (_) => 1,
          poolHealthCheck: (_) => 1,
          poolClose: (_) => 1,
        ),
      );
      final connStr = 'DSN=x'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(128);
      final outWritten = calloc<ffi.Uint32>();
      final versionBuf = calloc<ffi.Uint8>(32);
      final versionWritten = calloc<ffi.Uint32>();

      try {
        expect(bindings.odbc_set_log_level(2), isA<int>());
        expect(
          bindings.odbc_get_version(versionBuf, 32, versionWritten),
          isA<int>(),
        );
        expect(bindings.odbc_pool_create(connStr, 1), isA<int>());
        expect(bindings.odbc_pool_get_connection(0), isA<int>());
        expect(bindings.odbc_pool_release_connection(0), isA<int>());
        expect(bindings.odbc_pool_health_check(0), isA<int>());
        expect(bindings.odbc_pool_close(0), isA<int>());
        expect(bindings.odbc_metadata_cache_enable(10, 30), isA<int>());
        expect(
          bindings.odbc_metadata_cache_stats(outBuf, 128, outWritten),
          isA<int>(),
        );
        expect(bindings.odbc_metadata_cache_clear(), isA<int>());
        expect(
          bindings.odbc_get_connection_dbms_info(0, outBuf, 128, outWritten),
          isA<int>(),
        );
      } finally {
        calloc
          ..free(connStr)
          ..free(outBuf)
          ..free(outWritten)
          ..free(versionBuf)
          ..free(versionWritten);
      }
    });

    test('should_invoke_prepare_execute_and_detect_driver_on_production', () {
      final bindings = FakeOdbcBindings.production();
      final connStr = 'Driver={SQL Server};Server=.'
          .toNativeUtf8()
          .cast<odbc_bindings.Utf8>();
      final sql = 'SELECT 1'.toNativeUtf8().cast<odbc_bindings.Utf8>();
      final outBuf = calloc<ffi.Uint8>(64);
      final outWritten = calloc<ffi.Uint32>();
      final driverBuf = calloc<ffi.Int8>(64);

      try {
        expect(bindings.odbc_detect_driver(connStr, driverBuf, 64), isA<int>());
        final stmtId = bindings.odbc_prepare(0, sql, 0);
        expect(stmtId, isA<int>());
        expect(
          bindings.odbc_execute(
            stmtId,
            ffi.nullptr,
            0,
            0,
            100,
            outBuf,
            64,
            outWritten,
          ),
          isA<int>(),
        );
        expect(bindings.odbc_cancel(stmtId), isA<int>());
        expect(bindings.odbc_close_statement(stmtId), isA<int>());
        expect(bindings.odbc_clear_all_statements(), isA<int>());
      } finally {
        calloc
          ..free(connStr)
          ..free(sql)
          ..free(outBuf)
          ..free(outWritten)
          ..free(driverBuf);
      }
    });

    test('should_fallback_transaction_begin_v3_to_v2_when_v3_absent', () {
      var v2Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        capabilities: const TestOdbcBindingsCapabilities(
          supportsTransactionLockTimeout: false,
          supportsTransactionAccessMode: true,
        ),
        overrides: TestOdbcBindingsOverrides(
          transactionBeginV2: (connId, isolation, dialect, accessMode) {
            v2Calls++;
            return 22;
          },
        ),
      );

      final txnId = bindings.odbc_transaction_begin_v3(1, 2, 0, 1, 3000);

      expect(txnId, equals(22));
      expect(v2Calls, equals(1));
    });
  });
}
