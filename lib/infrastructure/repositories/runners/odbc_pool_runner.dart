import 'dart:convert';

import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/pool_state.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_connection_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Connection-pool family of operations.
class OdbcPoolRunner {
  OdbcPoolRunner({
    required this.ffi,
    required this.state,
    required this.connection,
    required this.emit,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcConnectionRunner connection;
  final EmitEventFn emit;

  Future<Result<int>> poolCreate(
    String connectionString,
    int maxSize, {
    PoolOptions? options,
    ConnectionOptions? connectionOptions,
  }) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    final validation = connectionOptions?.validate();
    if (validation != null) {
      return Failure(ValidationError(message: validation));
    }
    if (maxSize <= 0) {
      return const Failure<int, OdbcError>(
        ValidationError(message: 'Pool maxSize must be greater than zero'),
      );
    }
    if (!ffi.isAsync && !ffi.sync.isInitialized) {
      final r = await connection.initialize();
      final err = r.exceptionOrNull();
      if (err != null) {
        return Failure<int, OdbcError>(
          err is OdbcError ? err : const EnvironmentNotInitializedError(),
        );
      }
    }
    return ffi
        .runIntFfi(
      sync: (n) => n.poolCreate(connectionString, maxSize, options: options),
      async: (a) => a.poolCreate(connectionString, maxSize, options: options),
      isSuccess: (id) => id != 0,
      errorFactory: odbcConnectionErrorFactory,
      fallbackMessage: 'Failed to create pool',
    )
        .then((result) {
      if (result.isSuccess()) {
        state.poolConnectionOptions[result.getOrNull()!] = connectionOptions;
      }
      return result;
    });
  }

  Future<Result<Unit>> poolSetSize(int poolId, int newMaxSize) async {
    if (poolId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    if (newMaxSize <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Pool maxSize must be greater than zero'),
      );
    }
    final priorState = ffi.isAsync
        ? await ffi.async.poolGetState(poolId)
        : ffi.sync.poolGetState(poolId);
    final result = await ffi.runBoolFfi(
      sync: (n) => n.poolSetSize(poolId, newMaxSize),
      async: (a) => a.poolSetSize(poolId, newMaxSize),
      errorFactory: odbcConnectionErrorFactory,
      fallbackMessage: 'Failed to resize pool',
    );
    if (result.isSuccess() && priorState != null) {
      emit(
        PoolResize(
          timestamp: DateTime.now().toUtc(),
          poolId: poolId,
          oldSize: priorState.size,
          newSize: newMaxSize,
        ),
      );
    }
    return result;
  }

  Future<Result<Connection>> poolGetConnection(
    int poolId, {
    ConnectionOptions? options,
  }) async {
    if (poolId <= 0) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    final effectiveOptions = options ?? state.poolConnectionOptions[poolId];
    final validation = effectiveOptions?.validate();
    if (validation != null) {
      return Failure(ValidationError(message: validation));
    }
    try {
      final connId = ffi.isAsync
          ? await ffi.async.poolGetConnection(poolId)
          : ffi.sync.poolGetConnection(poolId);

      if (connId == 0) {
        return await ffi.convertNativeErrorToFailure<Connection>(
          errorFactory: odbcConnectionErrorFactory,
          fallbackMessage: 'Failed to get connection from pool',
        );
      }
      final c = Connection(
        id: connId.toString(),
        connectionString: '',
        createdAt: DateTime.now(),
        isActive: true,
      );
      state.connectionIds[c.id] = connId;
      state.connectionLifetimes[c.id] = Object();
      state.connectionStrings[c.id] = 'pool://$poolId';
      state.connectionOptions[c.id] =
          options ?? state.poolConnectionOptions[poolId];
      state.connectionPoolId[c.id] = poolId;
      state.poolCheckouts.putIfAbsent(poolId, () => <String>{}).add(c.id);
      return Success(c);
    } on Exception catch (e, stack) {
      return Failure<Connection, OdbcError>(
        translateOdbcError(
          e,
          operation: 'poolGetConnection',
          stackTrace: stack,
        ),
      );
    }
  }

  Future<Result<Unit>> poolReleaseConnection(String connectionId) async {
    void releaseMetadata() {
      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionStrings.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionLifetimes.remove(connectionId);
      final poolId = state.connectionPoolId.remove(connectionId);
      if (poolId != null) state.poolCheckouts[poolId]?.remove(connectionId);
    }

    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      if (state.connectionPoolId.containsKey(connectionId) &&
          state.connectionLifetimes.containsKey(connectionId)) {
        // Recovery already returned the old checkout. Invalidate the logical
        // lifetime so a later reacquisition is returned without publication.
        releaseMetadata();
        return const Success(unit);
      }
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }
    state.connectionLifetimes.remove(connectionId);
    return ffi.runBoolFfiWithCleanup(
      sync: (n) => n.poolReleaseConnection(nativeId),
      async: (a) => a.poolReleaseConnection(nativeId),
      onSuccess: releaseMetadata,
      errorFactory: odbcConnectionErrorFactory,
      fallbackMessage: 'Failed to release connection to pool',
    );
  }

  Future<Result<bool>> poolHealthCheck(int poolId) async {
    if (poolId <= 0) {
      return const Failure<bool, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    try {
      final result = ffi.isAsync
          ? await ffi.async.poolHealthCheck(poolId)
          : ffi.sync.poolHealthCheck(poolId);

      if (result) return const Success(true);
      return await ffi.convertNativeErrorToFailure<bool>(
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'Pool health check failed or pool does not exist',
      );
    } on Exception catch (e, stack) {
      return Failure<bool, OdbcError>(
        translateOdbcError(e, operation: 'poolHealthCheck', stackTrace: stack),
      );
    }
  }

  Future<Result<PoolState>> poolGetState(int poolId) async {
    if (poolId <= 0) {
      return const Failure<PoolState, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    try {
      final s = ffi.isAsync
          ? await ffi.async.poolGetState(poolId)
          : ffi.sync.poolGetState(poolId);

      if (s == null) {
        return await ffi.convertNativeErrorToFailure<PoolState>(
          errorFactory: odbcConnectionErrorFactory,
          fallbackMessage: 'Failed to get pool state',
        );
      }
      return Success(PoolState(size: s.size, idle: s.idle));
    } on Exception catch (e, stack) {
      return Failure<PoolState, OdbcError>(
        translateOdbcError(e, operation: 'poolGetState', stackTrace: stack),
      );
    }
  }

  Future<Result<Unit>> poolClose(int poolId) async {
    if (poolId <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Invalid pool ID'),
      );
    }
    (state.poolCheckouts[poolId] ?? const <String>{})
        .forEach(state.connectionLifetimes.remove);
    return ffi.runBoolFfiWithCleanup(
      sync: (n) => n.poolClose(poolId),
      async: (a) => a.poolClose(poolId),
      onSuccess: () {
        state.poolConnectionOptions.remove(poolId);
        final checkouts =
            state.poolCheckouts.remove(poolId) ?? const <String>{};
        for (final cId in checkouts) {
          state.clearStatementMetadataForConnection(cId);
          state.connectionIds.remove(cId);
          state.connectionLifetimes.remove(cId);
          state.connectionStrings.remove(cId);
          state.connectionOptions.remove(cId);
          state.connectionPoolId.remove(cId);
        }
      },
      errorFactory: odbcConnectionErrorFactory,
      fallbackMessage: 'Failed to close pool',
    );
  }

  Future<Result<Map<String, Object?>>> poolGetStateDetailed(int poolId) async {
    try {
      Map<String, Object?>? decoded;
      if (ffi.isAsync) {
        final payload = await ffi.async.poolGetStateJson(poolId);
        if (payload == null || payload.isEmpty) {
          return await ffi.convertNativeErrorToFailure<Map<String, Object?>>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'Failed to get detailed pool state',
          );
        }
        decoded = _decodeJsonMap(payload);
      } else {
        final payload = ffi.sync.poolGetStateJson(poolId);
        if (payload == null || payload.isEmpty) {
          return await ffi.convertNativeErrorToFailure<Map<String, Object?>>(
            errorFactory: odbcQueryErrorFactory,
            fallbackMessage: 'Failed to get detailed pool state',
          );
        }
        decoded = payload.map<String, Object?>(
          MapEntry<String, Object?>.new,
        );
      }
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid detailed pool state payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid detailed pool state JSON: ${e.message}'),
      );
    } on Exception catch (e, st) {
      return Failure<Map<String, Object?>, OdbcError>(
        translateOdbcError(
          e,
          operation: 'poolGetStateDetailed',
          stackTrace: st,
        ),
      );
    }
  }

  Map<String, Object?>? _decodeJsonMap(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return decoded.map<String, Object?>(
      MapEntry<String, Object?>.new,
    );
  }
}
