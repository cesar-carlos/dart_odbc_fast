/// Unit tests for [OdbcPoolRunner].
library;

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/pool_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_pool_runner.dart';
import 'package:test/test.dart';

class _FakeNativeForPool extends NativeOdbcConnection {
  bool nativeInitialized = true;
  int poolCreateResult = 5;
  int poolGetConnectionResult = 11;
  bool poolReleaseConnectionResult = true;
  bool poolSetSizeResult = true;
  ({int size, int idle})? poolGetStateResult = (size: 4, idle: 2);

  @override
  bool get isInitialized => nativeInitialized;

  @override
  int poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
  }) =>
      poolCreateResult;

  @override
  int poolGetConnection(int poolId) => poolGetConnectionResult;

  @override
  bool poolReleaseConnection(int connectionId) => poolReleaseConnectionResult;

  @override
  bool poolSetSize(int poolId, int newMaxSize) => poolSetSizeResult;

  @override
  ({int size, int idle})? poolGetState(int poolId) => poolGetStateResult;
}

void main() {
  group('OdbcPoolRunner', () {
    late _FakeNativeForPool native;
    late OdbcRepositoryState state;
    late OdbcPoolRunner runner;
    final events = <OdbcEvent>[];

    setUp(() {
      native = _FakeNativeForPool();
      state = OdbcRepositoryState();
      final ffi = OdbcFfiDispatch(SyncBackend(native));
      runner = OdbcPoolRunner(
        ffi: ffi,
        state: state,
        connection: OdbcConnectionRunner(
          ffi: ffi,
          state: state,
          emit: events.add,
          maybeEmitSlowQuery: ({
            required connectionId,
            required sql,
            stopwatch,
          }) {},
        ),
        emit: events.add,
      );
    });

    tearDown(() => native.dispose());

    test('should_reject_empty_connection_string_on_poolCreate', () async {
      final result = await runner.poolCreate('', 4);
      expect(result.isError(), isTrue);
      expect(result.exceptionOrNull(), isA<ValidationError>());
    });

    test('should_return_pool_id_when_native_succeeds', () async {
      final result = await runner.poolCreate('DSN=pool', 4);
      expect(result.isSuccess(), isTrue);
      expect(result.getOrNull(), equals(5));
    });

    test('should_track_checkout_state_on_poolGetConnection', () async {
      final result = await runner.poolGetConnection(5);
      expect(result.isSuccess(), isTrue);
      final conn = result.getOrNull()!;
      expect(state.connectionIds[conn.id], equals(11));
      expect(state.connectionPoolId[conn.id], equals(5));
      expect(state.poolCheckouts[5], contains(conn.id));
    });

    test('should_apply_pool_connection_options_on_checkout', () async {
      const poolOptions = ConnectionOptions(queryTimeout: Duration(seconds: 5));
      final create = await runner.poolCreate(
        'DSN=pool',
        4,
        connectionOptions: poolOptions,
      );
      expect(create.isSuccess(), isTrue);
      final poolId = create.getOrNull()!;

      final checkout = await runner.poolGetConnection(poolId);
      expect(checkout.isSuccess(), isTrue);
      final conn = checkout.getOrNull()!;
      expect(state.connectionOptions[conn.id], same(poolOptions));
    });

    test('should_allow_checkout_override_of_pool_connection_options', () async {
      const poolOptions = ConnectionOptions(queryTimeout: Duration(seconds: 5));
      const checkoutOptions = ConnectionOptions(
        queryTimeout: Duration(seconds: 9),
      );
      final create = await runner.poolCreate(
        'DSN=pool',
        4,
        connectionOptions: poolOptions,
      );
      final poolId = create.getOrNull()!;

      final checkout = await runner.poolGetConnection(
        poolId,
        options: checkoutOptions,
      );
      final conn = checkout.getOrNull()!;
      expect(state.connectionOptions[conn.id], same(checkoutOptions));
    });

    test('should_emit_PoolResize_when_poolSetSize_succeeds', () async {
      final result = await runner.poolSetSize(5, 8);
      expect(result.isSuccess(), isTrue);
      expect(events.whereType<PoolResize>(), hasLength(1));
      expect(events.whereType<PoolResize>().first.newSize, equals(8));
    });
  });
}
