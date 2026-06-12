import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';
import 'test_odbc_bindings.dart';

void main() {
  Uint8List catalogBytes() => Uint8List.fromList([0xCA, 0xFE]);

  group('OdbcNative Wave 7C catalog FFI', () {
    test('should_forward_catalog_and_schema_filters_on_catalog_tables', () {
      String? seenCatalog;
      String? seenSchema;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogTables:
                (connId, catalog, schema, outBuf, bufLen, outWritten) {
              expect(connId, equals(7));
              seenCatalog = FakeOdbcBindings.readUtf8Pointer(catalog);
              seenSchema = FakeOdbcBindings.readUtf8Pointer(schema);
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                catalogBytes(),
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.catalogTables(7, catalog: 'mydb', schema: 'dbo'),
        equals(catalogBytes()),
      );
      expect(seenCatalog, equals('mydb'));
      expect(seenSchema, equals('dbo'));
    });

    test('should_return_null_when_catalog_foreign_keys_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogForeignKeys: (_, __, ___, ____, _____) => 1,
          ),
        ),
      );

      expect(native.catalogForeignKeys(1, 'child'), isNull);
    });

    test('should_grow_catalog_foreign_keys_buffer_when_stub_returns_minus_two',
        () {
      var calls = 0;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogForeignKeys: (_, table, outBuf, bufLen, outWritten) {
              calls++;
              if (calls == 1) {
                outWritten.value = 5;
                return -2;
              }
              expect(
                FakeOdbcBindings.readUtf8Pointer(table),
                equals('fk_child'),
              );
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([0xAB, 0xCD]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.catalogForeignKeys(1, 'fk_child'),
        equals([0xAB, 0xCD]),
      );
      expect(calls, greaterThan(1));
    });

    test('should_grow_catalog_columns_buffer_when_stub_returns_minus_two', () {
      var calls = 0;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            catalogColumns: (_, table, outBuf, bufLen, outWritten) {
              calls++;
              if (calls == 1) {
                outWritten.value = 6;
                return -2;
              }
              expect(
                FakeOdbcBindings.readUtf8Pointer(table),
                equals('wide'),
              );
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([7, 8, 9]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(native.catalogColumns(1, 'wide'), equals([7, 8, 9]));
      expect(calls, greaterThan(1));
    });
  });

  group('OdbcNative Wave 7C execute variants', () {
    test('should_forward_timeout_and_fetch_size_on_execute', () {
      int? seenTimeout;
      int? seenFetchSize;
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
              expect(stmtId, equals(4));
              expect(params, equals(ffi.nullptr));
              expect(paramsLen, equals(0));
              seenTimeout = timeoutOverrideMs;
              seenFetchSize = fetchSize;
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([1]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.execute(4, null, 1500, 250),
        equals([1]),
      );
      expect(seenTimeout, equals(1500));
      expect(seenFetchSize, equals(250));
    });

    test('should_execute_typed_with_serialized_param_values', () {
      int? seenParamsLen;
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
              expect(stmtId, equals(2));
              seenParamsLen = paramsLen;
              expect(paramsLen, greaterThan(0));
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([0xFF]),
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.executeTyped(2, [const ParamValueInt32(42)]),
        equals([0xFF]),
      );
      expect(seenParamsLen, greaterThan(0));
    });

    test('should_delegate_execute_typed_to_execute_when_params_empty', () {
      int? seenParamsLen;
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
              expect(stmtId, equals(3));
              seenParamsLen = paramsLen;
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

      expect(native.executeTyped(3), equals([2]));
      expect(seenParamsLen, equals(0));
    });

    test('should_return_false_when_close_or_cancel_statement_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            prepare: (_, __, ___) => 9,
          ),
        ),
      );

      expect(native.prepare(1, 'SELECT 1'), equals(9));
      expect(native.closeStatement(9), isFalse);
      expect(native.cancelStatement(9), isFalse);
    });
  });

  group('OdbcNative Wave 7C stream fetch', () {
    test('should_report_has_more_when_stream_fetch_stub_sets_flag', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            streamStart: (_, __, ___) => 5,
            streamFetch: (
              streamId,
              outBuf,
              bufLen,
              outWritten,
              hasMore,
            ) {
              expect(streamId, equals(5));
              FakeOdbcBindings.writePayload(
                outBuf,
                bufLen,
                outWritten,
                Uint8List.fromList([1, 2]),
              );
              hasMore.value = 1;
              return 0;
            },
          ),
        ),
      );

      expect(native.streamStart(1, 'SELECT 1'), equals(5));
      final fetch = native.streamFetch(5);
      expect(fetch.success, isTrue);
      expect(fetch.data, equals([1, 2]));
      expect(fetch.hasMore, isTrue);
    });
  });

  group('OdbcNative Wave 7C transactions and savepoints', () {
    test('should_return_true_when_transaction_commit_native_returns_zero', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            transactionCommit: (_) => 0,
          ),
        ),
      );

      expect(native.transactionCommit(10), isTrue);
    });

    test('should_return_false_when_transaction_rollback_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            transactionRollback: (_) => 1,
          ),
        ),
      );

      expect(native.transactionRollback(10), isFalse);
    });

    test('should_forward_savepoint_name_to_native_helpers', () {
      final names = <String>[];
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            savepointCreate: (txnId, namePtr) {
              expect(txnId, equals(20));
              names.add(FakeOdbcBindings.readUtf8Pointer(namePtr));
              return 0;
            },
            savepointRollback: (txnId, namePtr) {
              expect(txnId, equals(20));
              names.add(FakeOdbcBindings.readUtf8Pointer(namePtr));
              return 0;
            },
            savepointRelease: (txnId, namePtr) {
              expect(txnId, equals(20));
              names.add(FakeOdbcBindings.readUtf8Pointer(namePtr));
              return 0;
            },
          ),
        ),
      );

      expect(native.savepointCreate(20, 'sp_a'), isTrue);
      expect(native.savepointRollback(20, 'sp_a'), isTrue);
      expect(native.savepointRelease(20, 'sp_a'), isTrue);
      expect(names, equals(['sp_a', 'sp_a', 'sp_a']));
    });
  });

  group('OdbcNative Wave 7C minus-one fallbacks', () {
    test(
      'should_return_null_for_structured_error_for_connection_'
      'when_native_returns_minus_one',
      () {
        final native = OdbcNative.withBindings(
          FakeOdbcBindings.stub(
            handlers: StubOdbcBindingsHandlers(
              forceSupportsStructuredErrorForConnection: true,
              structuredErrorForConnection: (_, __, ___, ____) => -1,
            ),
          ),
        );

        expect(native.getStructuredErrorForConnection(3), isNull);
      },
    );

    test('should_return_null_when_async_poll_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsAsyncExecuteApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            asyncPoll: (_, __) => 1,
          ),
        ),
      );

      expect(native.asyncPoll(99), isNull);
    });
  });
}
