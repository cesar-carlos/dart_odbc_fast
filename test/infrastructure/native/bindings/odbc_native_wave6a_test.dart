import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/bindings/test_odbc_bindings.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';

void main() {
  Uint8List catalogPayload() => Uint8List.fromList([0xCA, 0xFE]);

  group('OdbcNative connect and disconnect', () {
    test('should_return_connection_id_when_connect_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            connect: (_) => 42,
          ),
        ),
      );

      expect(native.connect('DSN=test'), equals(42));
    });

    test('should_return_zero_when_connect_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            connect: (_) => 0,
          ),
        ),
      );

      expect(native.connect('DSN=bad'), equals(0));
    });

    test('should_forward_timeout_to_connect_with_timeout', () {
      int? seenTimeout;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            hasConnectWithTimeoutSymbol: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            connectWithTimeout: (_, timeoutMs) {
              seenTimeout = timeoutMs;
              return 9;
            },
          ),
        ),
      );

      expect(native.connectWithTimeout('DSN=x', 5000), equals(9));
      expect(seenTimeout, equals(5000));
    });

    test('should_return_true_when_disconnect_native_returns_zero', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            disconnect: (_) => 0,
          ),
        ),
      );

      expect(native.disconnect(1), isTrue);
    });

    test('should_return_false_when_disconnect_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            disconnect: (_) => 1,
          ),
        ),
      );

      expect(native.disconnect(1), isFalse);
    });
  });

  group('OdbcNative prepare and execute', () {
    test('should_return_statement_id_and_forward_timeout_on_prepare', () {
      String? capturedSql;
      int? capturedTimeout;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            prepare: (connId, sql, timeoutMs) {
              capturedSql = FakeOdbcBindings.readUtf8Pointer(sql);
              capturedTimeout = timeoutMs;
              expect(connId, equals(3));
              return 11;
            },
          ),
        ),
      );

      expect(native.prepare(3, 'SELECT ?', timeoutMs: 2500), equals(11));
      expect(capturedSql, equals('SELECT ?'));
      expect(capturedTimeout, equals(2500));
    });

    test('should_return_bytes_when_execute_without_params_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execute: (
              stmtId,
              params,
              paramsLen,
              timeoutOverrideMs,
              fetchSize,
              outBuf,
              bufLen,
              outWritten,
            ) {
              expect(stmtId, equals(5));
              expect(paramsLen, equals(0));
              expect(timeoutOverrideMs, equals(100));
              expect(fetchSize, equals(50));
              final payload = Uint8List.fromList([7, 8]);
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                payload,
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.execute(5, null, 100, 50), equals([7, 8]));
    });

    test('should_return_bytes_when_execute_with_params_succeeds', () {
      var sawParams = false;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execute: (
              stmtId,
              params,
              paramsLen,
              _,
              __,
              outBuf,
              bufLen,
              outWritten,
            ) {
              sawParams = paramsLen > 0;
              final payload = Uint8List.fromList([1]);
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                payload,
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.execute(2, Uint8List.fromList([9])), equals([1]));
      expect(sawParams, isTrue);
    });

    test('should_return_null_when_execute_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execute: (_, __, ___, ____, _____, ______, _______, ________) => 1,
          ),
        ),
      );

      expect(native.execute(1), isNull);
    });
  });

  group('OdbcNative exec and catalog stubs', () {
    test('should_return_bytes_from_exec_query_params', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execQueryParams: (
              connId,
              sql,
              params,
              paramsLen,
              outBuf,
              bufLen,
              outWritten,
            ) {
              expect(connId, equals(2));
              expect(paramsLen, greaterThan(0));
              final payload = Uint8List.fromList([3, 4]);
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                payload,
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.execQueryParams(2, 'SELECT ?', Uint8List.fromList([1])),
        equals([3, 4]),
      );
    });

    test('should_grow_buffer_when_exec_query_returns_minus_two', () {
      var calls = 0;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execQuery: (_, __, outBuf, bufLen, outWritten) {
              calls++;
              if (calls == 1) {
                outWritten.value = 4;
                return -2;
              }
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([9, 9, 9, 9]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.execQuery(1, 'SELECT 1'), equals([9, 9, 9, 9]));
      expect(calls, greaterThan(1));
    });

    test('should_return_catalog_tables_bytes_from_stub', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogTables: (_, __, ___, outBuf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                catalogPayload(),
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.catalogTables(1), equals(catalogPayload()));
    });

    test('should_return_catalog_columns_bytes_from_stub', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogColumns: (_, table, outBuf, bufLen, outWritten) {
              expect(
                FakeOdbcBindings.readUtf8Pointer(table),
                equals('orders'),
              );
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                catalogPayload(),
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.catalogColumns(1, 'orders'), equals(catalogPayload()));
    });

    test('should_return_null_when_catalog_type_info_stub_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogTypeInfo: (_, __, ___, ____) => 1,
          ),
        ),
      );

      expect(native.catalogTypeInfo(1), isNull);
    });

    test('should_return_catalog_primary_keys_and_indexes_from_stub', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogPrimaryKeys: (_, __, outBuf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([1]),
              );
              return 0;
            },
            catalogIndexes: (_, __, outBuf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([2]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.catalogPrimaryKeys(1, 't'), equals([1]));
      expect(native.catalogIndexes(1, 't'), equals([2]));
    });
  });

  group('OdbcNative XA and buffer helpers', () {
    test('should_report_xa_unsupported_on_legacy_minimal_bindings', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(native.supportsXa, isFalse);
    });

    test('should_throw_when_xa_start_called_without_native_xa_api', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(
        () => native.xaStart(
          connectionId: 1,
          formatId: 0,
          gtrid: Uint8List.fromList([1]),
          bqual: Uint8List.fromList([2]),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('should_return_xa_id_when_xa_start_stub_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(supportsXa: true),
          overrides: TestOdbcBindingsOverrides(
            xaStart: (_, formatId, gtrid, gtridLen, bqual, bqualLen) {
              expect(formatId, equals(99));
              expect(gtridLen, equals(1));
              expect(bqualLen, equals(1));
              return 77;
            },
          ),
        ),
      );

      expect(
        native.xaStart(
          connectionId: 2,
          formatId: 99,
          gtrid: Uint8List.fromList([1]),
          bqual: Uint8List.fromList([2]),
        ),
        equals(77),
      );
    });

    test('should_delegate_exec_with_buffer_to_call_with_buffer', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.stub());

      final bytes = native.execWithBuffer((buf, bufLen, outWritten) {
        FakeOdbcBindings.writePayload(
          buf,
          bufLen,
          outWritten,
          Uint8List.fromList([5, 6]),
        );
        return 0;
      });

      expect(bytes, equals([5, 6]));
    });

    test('should_decode_connection_structured_error_when_stub_writes_payload',
        () {
      final payload = FakeOdbcBindings.structuredErrorPayload(
        sqlState: '40001',
        message: 'serialization failure',
      );
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            forceSupportsStructuredErrorForConnection: true,
            structuredErrorForConnection: (connId, buf, bufLen, outWritten) {
              expect(connId, equals(8));
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, payload);
              return 0;
            },
          ),
        ),
      );

      final error = native.getStructuredErrorForConnection(8);

      expect(error?.sqlStateString, equals('40001'));
      expect(error?.message, equals('serialization failure'));
    });
  });

  group('OdbcNative stream pool and driver', () {
    test('should_fetch_stream_chunks_when_stub_returns_payload', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            streamStart: (_, __, ___) => 3,
            streamFetch: (
              streamId,
              outBuf,
              bufLen,
              outWritten,
              hasMore,
            ) {
              expect(streamId, equals(3));
              final chunk = Uint8List.fromList([4, 5]);
              final n = chunk.length < bufLen ? chunk.length : bufLen;
              outBuf.asTypedList(n).setAll(0, chunk.sublist(0, n));
              outWritten.value = n;
              hasMore.value = 0;
              return 0;
            },
            streamClose: (id) {
              expect(id, equals(3));
              return 0;
            },
          ),
        ),
      );

      expect(native.streamStart(1, 'SELECT 1'), equals(3));
      final fetch = native.streamFetch(3);
      expect(fetch.success, isTrue);
      expect(fetch.data, equals([4, 5]));
      expect(fetch.hasMore, isFalse);
      expect(native.streamClose(3), isTrue);
    });

    test('should_grow_stream_fetch_buffer_when_stub_returns_minus_two', () {
      var calls = 0;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            streamStart: (_, __, ___) => 2,
            streamFetch: (
              _,
              outBuf,
              bufLen,
              outWritten,
              hasMore,
            ) {
              calls++;
              if (calls == 1) {
                outWritten.value = 8;
                return -2;
              }
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([1, 2, 3]),
              );
              hasMore.value = 0;
              return 0;
            },
          ),
        ),
      );

      expect(native.streamStart(1, 'SELECT 1'), equals(2));
      final fetch = native.streamFetch(2);
      expect(fetch.success, isTrue);
      expect(fetch.data, equals([1, 2, 3]));
      expect(calls, greaterThan(1));
    });

    test('should_return_false_when_stream_fetch_stub_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            streamStart: (_, __, ___) => 1,
            streamFetch: (_, __, ___, ____, _____) => 1,
          ),
        ),
      );

      expect(native.streamStart(1, 'SELECT 1'), equals(1));
      final fetch = native.streamFetch(1);
      expect(fetch.success, isFalse);
      expect(fetch.data, isNull);
    });

    test('should_return_driver_name_when_detect_driver_stub_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            detectDriver: (connStr, outBuf, bufLen) {
              expect(
                FakeOdbcBindings.readUtf8Pointer(connStr),
                equals('Driver={SQL Server}'),
              );
              final bytes = 'sqlserver'.codeUnits;
              final n = bytes.length < bufLen ? bytes.length : bufLen;
              for (var i = 0; i < n; i++) {
                outBuf[i] = bytes[i];
              }
              if (n < bufLen) {
                outBuf[n] = 0;
              }
              return 1;
            },
          ),
        ),
      );

      expect(native.detectDriver('Driver={SQL Server}'), equals('sqlserver'));
    });

    test('should_return_null_for_driver_capabilities_when_api_unsupported', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(native.getDriverCapabilitiesJson('DSN=x'), isNull);
    });

    test('should_decode_driver_capabilities_json_when_stub_writes_payload', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsDriverCapabilitiesApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            getDriverCapabilities: (_, buf, bufLen, outWritten) {
              final json = utf8.encode('{"driver":"sqlserver"}');
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, json);
              return 0;
            },
          ),
        ),
      );

      expect(
        native.getDriverCapabilitiesJson('DSN=x'),
        equals('{"driver":"sqlserver"}'),
      );
    });

    test('should_return_pool_id_from_pool_create_stub', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            poolCreate: (_, maxSize) {
              expect(maxSize, equals(3));
              return 15;
            },
          ),
        ),
      );

      expect(native.poolCreate('DSN=pool', 3), equals(15));
    });

    test('should_parse_metrics_when_get_metrics_stub_writes_payload', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            getMetrics: (buf, bufLen, outWritten) {
              final payload = FakeOdbcBindings.metricsPayload(
                queryCount: 99,
                avgLatencyMillis: 12,
              );
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, payload);
              return 0;
            },
          ),
        ),
      );

      final metrics = native.getMetrics();

      expect(metrics?.queryCount, equals(99));
      expect(metrics?.avgLatencyMillis, equals(12));
    });

    test('should_forward_xa_end_to_bindings_stub', () {
      var seenXaId = 0;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            xaEnd: (xaId) {
              seenXaId = xaId;
              return 0;
            },
          ),
        ),
      );

      expect(native.xaEnd(44), equals(0));
      expect(seenXaId, equals(44));
    });

    test('should_close_and_cancel_statement_via_native_bindings', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            prepare: (_, __, ___) => 6,
          ),
        ),
      );

      expect(native.prepare(1, 'SELECT 1'), equals(6));
      expect(native.closeStatement(6), isA<bool>());
      expect(native.cancelStatement(6), isA<bool>());
    });
  });
}
