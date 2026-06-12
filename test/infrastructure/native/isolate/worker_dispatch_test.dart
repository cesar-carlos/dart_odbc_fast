/// Worker [handleWorkerRequestForTesting] dispatch with injected native stubs.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    show Utf8;
import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:test/test.dart';

import '../bindings/fake_odbc_bindings.dart';
import '../bindings/test_odbc_bindings.dart';

final _emptyParams = Uint8List(0);

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

int _metricsFfiFailure(
  ffi.Pointer<ffi.Uint8> _,
  int __,
  ffi.Pointer<ffi.Uint32> ___,
) =>
    -1;

NativeOdbcConnection _connection(
  TestOdbcBindingsOverrides overrides, {
  TestOdbcBindingsCapabilities capabilities =
      const TestOdbcBindingsCapabilities(),
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

NativeOdbcConnection _stubConnection({
  TestOdbcBindingsOverrides overrides = const TestOdbcBindingsOverrides(),
  StubOdbcBindingsHandlers handlers = const StubOdbcBindingsHandlers(),
}) {
  return NativeOdbcConnection.testing(
    OdbcNative.withBindings(
      FakeOdbcBindings.stub(
        overrides: overrides,
        handlers: handlers,
      ),
    ),
  );
}

Future<T> _dispatch<T extends WorkerResponse>(
  WorkerRequest request,
  NativeOdbcConnection conn,
) async {
  final receivePort = ReceivePort();
  addTearDown(receivePort.close);
  final responseFuture = receivePort.first;
  handleWorkerRequestForTesting(request, receivePort.sendPort, conn);
  return await responseFuture as T;
}

void main() {
  group('worker dispatch', timeout: const Timeout(Duration(minutes: 2)), () {
    test('should_initialize_and_return_bool_success', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(init: () => 0),
      );
      addTearDown(conn.dispose);

      final response = await _dispatch<InitializeResponse>(
        const InitializeRequest(1),
        conn,
      );

      expect(response.success, isTrue);
    });

    test('should_validate_connection_string_when_native_succeeds', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          validateConnectionString: (_, __, ___) => 0,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ValidateConnectionStringResponse>(
        const ValidateConnectionStringRequest(2, 'Driver={Test}'),
        conn,
      );

      expect(response.isValid, isTrue);
      expect(response.errorMessage, isNull);
    });

    test('should_map_validation_failure_to_error_message', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          validateConnectionString:
              FakeOdbcBindings.validateConnectionStringReturns('bad driver'),
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ValidateConnectionStringResponse>(
        const ValidateConnectionStringRequest(3, 'invalid'),
        conn,
      );

      expect(response.isValid, isFalse);
      expect(response.errorMessage, 'bad driver');
    });

    test('should_connect_with_timeout_when_timeoutMs_positive', () async {
      var timeoutUsed = false;
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: () => 0,
          connectWithTimeout: (_, __) {
            timeoutUsed = true;
            return 7;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ConnectResponse>(
        const ConnectRequest(4, 'Driver={Test}', timeoutMs: 5000),
        conn,
      );

      expect(timeoutUsed, isTrue);
      expect(response.connectionId, 7);
      expect(response.error, isNull);
    });

    test('should_return_connect_error_when_native_returns_zero', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: () => 0,
          connect: (_) => 0,
          getError: FakeOdbcBindings.getErrorWrites('login failed'),
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ConnectResponse>(
        const ConnectRequest(5, 'Driver={Test}'),
        conn,
      );

      expect(response.connectionId, isZero);
      expect(response.error, 'login failed');
    });

    test('should_set_log_level_and_acknowledge_with_bool_true', () async {
      final conn = _connection(TestOdbcBindingsOverrides(init: () => 0));
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const SetLogLevelRequest(6, 2),
        conn,
      );

      expect(response.value, isTrue);
    });

    test('should_begin_transaction_with_wire_codes', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: () => 0,
          transactionBeginV3: (_, __, ___, ____, _____) => 99,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<IntResponse>(
        const BeginTransactionRequest(
          7,
          1,
          2,
          savepointDialect: 1,
          accessMode: 1,
          lockTimeoutMs: 3000,
        ),
        conn,
      );

      expect(response.value, 99);
    });

    test('should_forward_get_error_message', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: () => 0,
          getError: FakeOdbcBindings.getErrorWrites('last native fault'),
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<GetErrorResponse>(
        const GetErrorRequest(8),
        conn,
      );

      expect(response.message, 'last native fault');
    });

    test('should_return_initialize_false_when_native_init_fails', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(init: () => 1),
      );
      addTearDown(conn.dispose);

      final response = await _dispatch<InitializeResponse>(
        const InitializeRequest(10),
        conn,
      );

      expect(response.success, isFalse);
    });

    test('should_connect_without_timeout_when_timeout_ms_is_zero', () async {
      var usedConnect = false;
      var usedTimeout = false;
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          connect: (_) {
            usedConnect = true;
            return 5;
          },
          connectWithTimeout: (_, __) {
            usedTimeout = true;
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ConnectResponse>(
        const ConnectRequest(11, 'Driver={Test}'),
        conn,
      );

      expect(usedConnect, isTrue);
      expect(usedTimeout, isFalse);
      expect(response.connectionId, 5);
      expect(response.error, isNull);
    });

    test('should_use_connect_failed_when_error_buffer_empty', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          connect: (_) => 0,
          getError: (_, __) => 0,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<ConnectResponse>(
        const ConnectRequest(12, 'Driver={Test}'),
        conn,
      );

      expect(response.connectionId, isZero);
      expect(response.error, 'Connect failed');
    });

    test('should_return_query_data_when_execute_query_multi_succeeds',
        () async {
      final conn = _stubConnection(
        overrides: const TestOdbcBindingsOverrides(init: _initSuccess),
        handlers: StubOdbcBindingsHandlers(
          execQueryMulti: (_, __, outBuf, bufLen, outWritten) {
            FakeOdbcBindings.writePayload(
              outBuf,
              bufLen,
              outWritten,
              Uint8List.fromList([1, 2, 3]),
            );
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<QueryResponse>(
        const ExecuteQueryMultiRequest(13, 1, 'SELECT 1'),
        conn,
      );

      expect(response.error, isNull);
      expect(response.data, equals([1, 2, 3]));
    });

    test('should_map_execute_query_params_failure_to_native_error', () async {
      final conn = _stubConnection(
        overrides: TestOdbcBindingsOverrides(
          init: _initSuccess,
          getError: FakeOdbcBindings.getErrorWrites('syntax error'),
        ),
        handlers: const StubOdbcBindingsHandlers(
          execQuery: _execQueryNativeFailure,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<QueryResponse>(
        ExecuteQueryParamsRequest(14, 1, 'SELECT bad', _emptyParams),
        conn,
      );

      expect(response.data, isNull);
      expect(response.error, 'syntax error');
    });

    test('should_use_fallback_when_execute_query_params_fails_with_no_error',
        () async {
      final conn = _stubConnection(
        overrides: TestOdbcBindingsOverrides(
          init: _initSuccess,
          getError: FakeOdbcBindings.getErrorWrites('No error'),
        ),
        handlers: const StubOdbcBindingsHandlers(
          execQuery: _execQueryNativeFailure,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<QueryResponse>(
        ExecuteQueryParamsRequest(15, 1, 'SELECT 1', _emptyParams),
        conn,
      );

      expect(response.error, contains('Query failed'));
      expect(response.error, contains('native returned no data'));
    });

    test('should_return_metrics_fields_when_get_metrics_succeeds', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          getMetrics: (buffer, bufferLen, outWritten) {
            final bytes = _metricsWireBytes(
              queryCount: 42,
              errorCount: 3,
              uptimeSecs: 120,
              totalLatencyMillis: 9000,
              avgLatencyMillis: 90,
            );
            final n = bytes.length < bufferLen ? bytes.length : bufferLen;
            buffer.asTypedList(n).setAll(0, bytes.sublist(0, n));
            outWritten.value = 40;
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<MetricsResponse>(
        const GetMetricsRequest(16),
        conn,
      );

      expect(response.error, isNull);
      expect(response.queryCount, 42);
      expect(response.errorCount, 3);
      expect(response.uptimeSecs, 120);
      expect(response.totalLatencyMillis, 9000);
      expect(response.avgLatencyMillis, 90);
    });

    test('should_return_metrics_error_when_native_get_metrics_fails', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          getMetrics: _metricsFfiFailure,
          getError: FakeOdbcBindings.getErrorWrites('metrics unavailable'),
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<MetricsResponse>(
        const GetMetricsRequest(17),
        conn,
      );

      expect(response.error, 'metrics unavailable');
    });

    test('should_return_driver_capabilities_json_payload', () async {
      const payload = '{"driver":"sqlserver"}';
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          getDriverCapabilities: (_, buffer, bufferLen, outWritten) {
            final bytes = utf8.encode(payload);
            FakeOdbcBindings.writePayload(
              buffer,
              bufferLen,
              outWritten,
              bytes,
            );
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<AuditPayloadResponse>(
        const GetDriverCapabilitiesRequest(18, 'Driver={SQL Server}'),
        conn,
      );

      expect(response.error, isNull);
      expect(response.payload, payload);
    });

    test('should_return_driver_capabilities_error_when_api_unavailable',
        () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          getError: FakeOdbcBindings.getErrorWrites('capabilities unsupported'),
        ),
        capabilities: const TestOdbcBindingsCapabilities(
          supportsDriverCapabilitiesApi: false,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<AuditPayloadResponse>(
        const GetDriverCapabilitiesRequest(19, 'Driver={Test}'),
        conn,
      );

      expect(response.payload, isNull);
      expect(response.error, 'capabilities unsupported');
    });

    test('should_return_stream_fetch_success_with_chunk_data', () async {
      final frame = FakeOdbcBindings.minimalStreamRowMajorFrame();
      final fetchOverride = FakeOdbcBindings.streamFetchChunks([frame]);
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          streamStart: (_, __, ___) => 9,
          streamFetch: fetchOverride.streamFetch,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<StreamFetchResponse>(
        const StreamFetchRequest(20, 9),
        conn,
      );

      expect(response.success, isTrue);
      expect(response.error, isNull);
      expect(response.data, isNotNull);
      expect(response.data!.length, greaterThan(0));
    });

    test('should_return_structured_error_fields_when_native_provides_payload',
        () async {
      final conn = _stubConnection(
        overrides: const TestOdbcBindingsOverrides(init: _initSuccess),
        handlers: StubOdbcBindingsHandlers(
          structuredError: (buffer, bufferLen, outWritten) {
            final payload = FakeOdbcBindings.structuredErrorPayload(
              sqlState: '42000',
              nativeCode: 7,
              message: 'worker structured fault',
            );
            FakeOdbcBindings.writePayload(
              buffer,
              bufferLen,
              outWritten,
              payload,
            );
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<StructuredErrorResponse>(
        const GetStructuredErrorRequest(21),
        conn,
      );

      expect(response.message, 'worker structured fault');
      expect(response.sqlStateString, '42000');
      expect(response.nativeCode, 7);
      expect(response.error, isNull);
    });

    test('should_create_savepoint_when_native_returns_success', () async {
      String? capturedName;
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          savepointCreate: (txnId, name) {
            expect(txnId, 10);
            capturedName = FakeOdbcBindings.readUtf8Pointer(name);
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const SavepointCreateRequest(30, 10, 'checkpoint_a'),
        conn,
      );

      expect(response.value, isTrue);
      expect(capturedName, 'checkpoint_a');
    });

    test('should_rollback_to_savepoint_when_native_returns_success', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          savepointRollback: (txnId, name) {
            expect(txnId, 11);
            expect(FakeOdbcBindings.readUtf8Pointer(name), 'sp_rollback');
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const SavepointRollbackRequest(31, 11, 'sp_rollback'),
        conn,
      );

      expect(response.value, isTrue);
    });

    test('should_return_false_when_savepoint_release_fails', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          savepointRelease: (_, __) => 1,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const SavepointReleaseRequest(32, 12, 'sp_release'),
        conn,
      );

      expect(response.value, isFalse);
    });

    test('should_commit_transaction_when_native_returns_success', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          transactionCommit: (txnId) {
            expect(txnId, 20);
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const CommitTransactionRequest(33, 20),
        conn,
      );

      expect(response.value, isTrue);
    });

    test('should_close_stream_when_native_stream_close_succeeds', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          streamClose: (streamId) {
            expect(streamId, 9);
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const StreamCloseRequest(34, 9),
        conn,
      );

      expect(response.value, isTrue);
    });

    test('should_return_false_when_stream_close_native_fails', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          streamClose: (_) => 1,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<BoolResponse>(
        const StreamCloseRequest(35, 2),
        conn,
      );

      expect(response.value, isFalse);
    });

    test('should_return_pool_id_from_pool_create_dispatch', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          poolCreate: (_, maxSize) {
            expect(maxSize, 4);
            return 15;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<IntResponse>(
        const PoolCreateRequest(36, 'Driver={Test}', 4),
        conn,
      );

      expect(response.value, 15);
    });

    test('should_use_pool_create_with_options_when_options_json_set', () async {
      var usedWithOptions = false;
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          poolCreate: (_, __) => 1,
          poolCreateWithOptions: (_, maxSize, optionsJson) {
            usedWithOptions = true;
            expect(maxSize, 6);
            expect(optionsJson, isNotNull);
            return 22;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<IntResponse>(
        const PoolCreateRequest(
          37,
          'Driver={Test}',
          6,
          optionsJson: '{"idle":1}',
        ),
        conn,
      );

      expect(usedWithOptions, isTrue);
      expect(response.value, 22);
    });

    test('should_return_pooled_connection_id_from_pool_get_dispatch', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          poolGetConnection: (poolId) {
            expect(poolId, 15);
            return 88;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<IntResponse>(
        const PoolGetConnectionRequest(38, 15),
        conn,
      );

      expect(response.value, 88);
    });

    test('should_return_pool_state_size_and_idle_when_native_succeeds',
        () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          poolGetState: (poolId, outSize, outIdle) {
            expect(poolId, 15);
            outSize.value = 5;
            outIdle.value = 2;
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<PoolStateResponse>(
        const PoolGetStateRequest(39, 15),
        conn,
      );

      expect(response.error, isNull);
      expect(response.size, 5);
      expect(response.idle, 2);
    });

    test('should_return_pool_state_error_when_native_get_state_fails',
        () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          poolGetState: (_, __, ___) => 1,
          getError: FakeOdbcBindings.getErrorWrites('pool state unavailable'),
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<PoolStateResponse>(
        const PoolGetStateRequest(40, 99),
        conn,
      );

      expect(response.size, isNull);
      expect(response.idle, isNull);
      expect(response.error, 'pool state unavailable');
    });

    test('should_return_async_request_id_from_execute_async_start', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          executeAsync: (_, __) => 55,
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final response = await _dispatch<IntResponse>(
        const ExecuteAsyncStartRequest(41, 1, 'SELECT 1'),
        conn,
      );

      expect(response.value, 55);
    });

    test('should_forward_async_poll_status_and_ack_cancel_free', () async {
      final conn = _connection(
        TestOdbcBindingsOverrides(
          init: _initSuccess,
          asyncPoll: (requestId, outStatus) {
            expect(requestId, 55);
            outStatus.value = 1;
            return 0;
          },
          asyncCancel: (requestId) {
            expect(requestId, 55);
            return 0;
          },
          asyncFree: (requestId) {
            expect(requestId, 55);
            return 0;
          },
        ),
      );
      addTearDown(conn.dispose);
      await _dispatch<InitializeResponse>(const InitializeRequest(0), conn);

      final poll = await _dispatch<IntResponse>(
        const AsyncPollRequest(42, 55),
        conn,
      );
      final cancel = await _dispatch<BoolResponse>(
        const AsyncCancelRequest(43, 55),
        conn,
      );
      final free = await _dispatch<BoolResponse>(
        const AsyncFreeRequest(44, 55),
        conn,
      );

      expect(poll.value, 1);
      expect(cancel.value, isTrue);
      expect(free.value, isTrue);
    });
  });
}

int _execQueryNativeFailure(
  int _,
  ffi.Pointer<Utf8> __,
  ffi.Pointer<ffi.Uint8> ___,
  int ____,
  ffi.Pointer<ffi.Uint32> _____,
) =>
    1;
