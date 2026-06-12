import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';
import 'test_odbc_bindings.dart';

void main() {
  group('OdbcNative structured error', () {
    test('should_decode_structured_error_when_native_writes_payload', () {
      final payload = FakeOdbcBindings.structuredErrorPayload(
        sqlState: '42S02',
        nativeCode: 815,
        message: 'table missing',
      );
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            structuredError: (buf, bufLen, outWritten) {
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, payload);
              return 0;
            },
          ),
        ),
      );

      final error = native.getStructuredError();

      expect(error, isNotNull);
      expect(error!.sqlStateString, equals('42S02'));
      expect(error.nativeCode, equals(815));
      expect(error.message, equals('table missing'));
    });

    test('should_return_null_when_structured_error_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            structuredError: (_, __, ___) => 1,
          ),
        ),
      );

      expect(native.getStructuredError(), isNull);
    });

    test('should_grow_buffer_when_structured_error_returns_minus_two', () {
      var calls = 0;
      final payload = FakeOdbcBindings.structuredErrorPayload(message: 'grown');
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            structuredError: (buf, bufLen, outWritten) {
              calls++;
              if (calls == 1) {
                outWritten.value = payload.length;
                return -2;
              }
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, payload);
              return 0;
            },
          ),
        ),
      );

      expect(native.getStructuredError()?.message, equals('grown'));
      expect(calls, greaterThan(1));
    });

    test('should_return_null_for_connection_error_when_api_unsupported', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: const StubOdbcBindingsHandlers(
            forceSupportsStructuredErrorForConnection: false,
          ),
        ),
      );

      expect(native.getStructuredErrorForConnection(1), isNull);
      expect(native.supportsStructuredErrorForConnection, isFalse);
    });

    test('should_return_null_when_connection_has_no_structured_error', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            forceSupportsStructuredErrorForConnection: true,
            structuredErrorForConnection: (_, __, ___, ____) => 1,
          ),
        ),
      );

      expect(native.getStructuredErrorForConnection(9), isNull);
    });

    test('should_grow_buffer_for_connection_structured_error_on_minus_two', () {
      var calls = 0;
      final payload = FakeOdbcBindings.structuredErrorPayload(
        nativeCode: 7,
        message: 'conn err',
      );
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            forceSupportsStructuredErrorForConnection: true,
            structuredErrorForConnection: (connId, buf, bufLen, outWritten) {
              expect(connId, equals(3));
              calls++;
              if (calls == 1) {
                outWritten.value = payload.length;
                return -2;
              }
              FakeOdbcBindings.writePayload(buf, bufLen, outWritten, payload);
              return 0;
            },
          ),
        ),
      );

      final error = native.getStructuredErrorForConnection(3);

      expect(error?.message, equals('conn err'));
      expect(calls, greaterThan(1));
    });
  });

  group('OdbcNative exec paths', () {
    test('should_return_query_bytes_when_exec_query_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execQuery: (_, __, outBuf, bufLen, outWritten) {
              final payload = Uint8List.fromList([1, 2, 3]);
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

      expect(native.execQuery(1, 'SELECT 1'), equals([1, 2, 3]));
    });

    test('should_return_null_when_exec_query_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execQuery: (_, __, ___, ____, _____) => 1,
          ),
        ),
      );

      expect(native.execQuery(1, 'SELECT 1'), isNull);
    });

    test('should_return_bytes_from_exec_query_multi', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            execQueryMulti: (_, __, outBuf, bufLen, outWritten) {
              final payload = Uint8List.fromList([9, 8]);
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

      expect(native.execQueryMulti(2, 'BATCH'), equals([9, 8]));
    });

    test('should_return_bytes_from_exec_query_multi_params_without_params', () {
      var sawZeroParamLen = false;
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsExecQueryMultiParams: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            execQueryMultiParams: (
              connId,
              sql,
              paramsBuffer,
              paramsLen,
              outBuffer,
              bufferLen,
              outWritten,
            ) {
              if (paramsLen == 0) {
                sawZeroParamLen = true;
              }
              final payload = Uint8List.fromList([5]);
              FakeOdbcBindings.writePayload(
                outBuffer,
                bufferLen,
                outWritten,
                payload,
              );
              return 0;
            },
          ),
        ),
      );

      expect(
        native.execQueryMultiParams(1, 'EXEC batch', null),
        equals([5]),
      );
      expect(sawZeroParamLen, isTrue);
    });
  });

  group('OdbcNative stream multi', () {
    test('should_return_null_for_stream_multi_batched_when_unsupported', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: const StubOdbcBindingsHandlers(
            forceSupportsMultiResultStream: false,
          ),
        ),
      );

      expect(native.streamMultiStartBatched(1, 'SELECT 1'), isNull);
    });

    test('should_return_null_for_stream_multi_async_when_unsupported', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: const StubOdbcBindingsHandlers(
            forceSupportsAsyncMultiResultStream: false,
          ),
        ),
      );

      expect(native.streamMultiStartAsync(1, 'SELECT 1'), isNull);
    });

    test('should_return_stream_id_for_stream_multi_batched_when_supported', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            forceSupportsMultiResultStream: true,
            streamMultiStartBatched: (_, __, ___) => 77,
          ),
        ),
      );

      expect(native.streamMultiStartBatched(1, 'SELECT 1'), equals(77));
    });

    test('should_return_stream_id_for_stream_multi_async_when_supported', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.stub(
          handlers: StubOdbcBindingsHandlers(
            forceSupportsAsyncMultiResultStream: true,
            streamMultiStartAsync: (_, __, ___) => 88,
          ),
        ),
      );

      expect(native.streamMultiStartAsync(2, 'SELECT 2'), equals(88));
    });
  });

  group('OdbcNative pool and audit edge cases', () {
    test('should_return_pool_id_from_pool_create_with_options_when_supported',
        () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsPoolCreateWithOptions: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            poolCreateWithOptions: (_, maxSize, __) {
              expect(maxSize, equals(4));
              return 12;
            },
          ),
        ),
      );

      expect(
        native.poolCreateWithOptions('DSN=x', 4, optionsJson: '{"idle":1}'),
        equals(12),
      );
    });

    test('should_return_false_when_set_audit_enabled_native_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsAuditApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            auditEnable: (_) => -1,
          ),
        ),
      );

      expect(native.setAuditEnabled(enabled: true), isFalse);
    });

    test('should_return_null_for_audit_events_json_when_buffer_call_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          capabilities: const TestOdbcBindingsCapabilities(
            supportsAuditApi: true,
          ),
          overrides: TestOdbcBindingsOverrides(
            auditGetEvents: (_, __, ___, ____) => 1,
          ),
        ),
      );

      expect(native.getAuditEventsJson(), isNull);
    });
  });
}
