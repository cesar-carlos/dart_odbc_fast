import 'dart:async';
import 'dart:isolate';

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_async_lifecycle_runner.dart';
import 'package:test/test.dart';

void _worker(SendPort parent) {
  final port = ReceivePort();
  parent.send(port.sendPort);
  port.listen((message) {
    if (message == 'shutdown') {
      port.close();
      return;
    }
    if (message is! WorkerRequest) return;
    switch (message) {
      case InitializeRequest():
        parent.send(InitializeResponse(message.requestId, success: true));
      case PoolCreateRequest():
        parent.send(IntResponse(message.requestId, 3));
      case PoolGetConnectionRequest():
        parent.send(IntResponse(message.requestId, 7));
      case ConnectRequest():
        parent.send(ConnectResponse(message.requestId, 7));
      case PoolReleaseConnectionRequest() ||
            PoolCloseRequest() ||
            AsyncFreeRequest():
        Timer(const Duration(milliseconds: 80), () {
          parent.send(BoolResponse(message.requestId, value: true));
        });
      default:
        throw StateError('Unexpected request ${message.runtimeType}');
    }
  });
}

void main() {
  for (final closePool in [false, true]) {
    test('should_clear_pool_metadata_after_late_confirmation_$closePool',
        () async {
      final native = AsyncNativeOdbcConnection(
        isolateEntry: _worker,
        requestTimeout: const Duration(milliseconds: 30),
      );
      final repository = OdbcRepositoryImpl(native);
      addTearDown(repository.dispose);
      await repository.initialize();
      final pool = (await repository.poolCreate('fake', 1)).getOrNull()!;
      final connection = (await repository.poolGetConnection(
        pool,
        options: const ConnectionOptions(),
      ))
          .getOrNull()!;
      final result = closePool
          ? await repository.poolClose(pool)
          : await repository.poolReleaseConnection(connection.id);
      expect(
        (result.exceptionOrNull()! as OdbcError).code,
        OdbcErrorCode.timeout,
      );
      final error = result.exceptionOrNull()! as OdbcError;
      expect(
        error.details.operation,
        closePool ? 'poolClose' : 'poolReleaseConnection',
      );
      expect(error.details.requestId, isNotNull);
      expect(repository.dartSideMetrics().poolCheckoutCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 140));
      final metrics = repository.dartSideMetrics();
      expect(metrics.connectionCount, 0);
      expect(metrics.poolCheckoutCount, 0);
      expect(metrics.pooledConnectionCount, 0);
      expect(metrics.connectionOptionsCount, 0);
      expect(result.isError(), isTrue);
    });
  }
  test('should_clear_async_owner_only_after_late_free_confirmation', () async {
    final native = AsyncNativeOdbcConnection(
      isolateEntry: _worker,
      requestTimeout: const Duration(milliseconds: 30),
    );
    addTearDown(native.dispose);
    await native.initialize();
    final state = OdbcRepositoryState()
      ..connectionIds['connection'] = 7
      ..connectionLifetimes['connection'] = Object()
      ..asyncRequestConnectionById[11] = 'connection';
    final runner = StreamAsyncLifecycleRunner(
      ffi: OdbcFfiDispatch(AsyncBackend(native)),
      state: state,
      parser: const OdbcResultParser(),
    );
    final result =
        await NativeCallContext.run('asyncFree', () => runner.asyncFree(11));
    expect(result.isError(), isTrue);
    expect(
      (result.exceptionOrNull()! as OdbcError).details.requestId,
      isNotNull,
    );
    expect(state.asyncRequestConnectionById, contains(11));
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(state.asyncRequestConnectionById, isEmpty);
  });
}
