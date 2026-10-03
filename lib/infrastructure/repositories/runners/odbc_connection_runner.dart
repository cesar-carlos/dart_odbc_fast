import 'dart:async';

import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/errors/odbc_error_boundary.dart';
import 'package:odbc_fast/infrastructure/native/errors/native_call_context.dart';
import 'package:odbc_fast/infrastructure/native/errors/odbc_error_translator.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:result_dart/result_dart.dart';

/// Connection lifecycle: initialize, connect, disconnect, reconnect policy.
class OdbcConnectionRunner {
  OdbcConnectionRunner({
    required this.ffi,
    required this.state,
    required this.emit,
    required this.maybeEmitSlowQuery,
  });

  final Map<String, Future<Result<Unit>>> _recoveries = {};

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final EmitEventFn emit;
  final void Function({
    required String connectionId,
    required String? sql,
    required Stopwatch? stopwatch,
  }) maybeEmitSlowQuery;

  Future<Result<Unit>> initialize() async {
    try {
      final success =
          ffi.isAsync ? await ffi.async.initialize() : ffi.sync.initialize();

      if (success) {
        return const Success(unit);
      }
      return Failure<Unit, OdbcError>(
        NativeCallContext.takeFailure() ??
            const EnvironmentNotInitializedError(),
      );
    } on Exception catch (e, stack) {
      return Failure<Unit, OdbcError>(
        translateOdbcError(
          e,
          operation: 'initialize',
          stackTrace: stack,
        ),
      );
    }
  }

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  }) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Connection, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    final optionsValidation = options?.validate();
    if (optionsValidation != null) {
      return Failure<Connection, OdbcError>(
        ValidationError(message: optionsValidation),
      );
    }

    try {
      final timeoutMs = options?.loginTimeoutMs ?? 0;
      final connId = ffi.isAsync
          ? await ffi.async.connect(connectionString, timeoutMs: timeoutMs)
          : (timeoutMs > 0
              ? ffi.sync.connectWithTimeout(connectionString, timeoutMs)
              : ffi.sync.connect(connectionString));

      if (connId == 0) {
        return await ffi.convertNativeErrorToFailure<Connection>(
          errorFactory: odbcConnectionErrorFactory,
          fallbackMessage: 'Failed to connect to database',
        );
      }

      final connection = Connection(
        id: connId.toString(),
        connectionString: connectionString,
        createdAt: DateTime.now(),
        isActive: true,
      );

      state.connectionIds[connection.id] = connId;
      state.connectionLifetimes[connection.id] = Object();
      state.connectionOptions[connection.id] = options;
      state.connectionStrings[connection.id] = connectionString;

      return Success(connection);
    } on Exception catch (e, stack) {
      return Failure<Connection, OdbcError>(
        translateOdbcError(
          e,
          operation: 'connect',
          stackTrace: stack,
        ),
      );
    }
  }

  Future<Result<Unit>> disconnect(String connectionId) async {
    if (state.connectionPoolId.containsKey(connectionId)) {
      return const Failure(
        ValidationError(
          message: 'Cannot disconnect a pooled connection. '
              'Use poolReleaseConnection instead.',
        ),
      );
    }
    final lifetime = state.connectionLifetimes.remove(connectionId);
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      if (lifetime != null) {
        state.clearStatementMetadataForConnection(connectionId);
        state.connectionOptions.remove(connectionId);
        state.connectionStrings.remove(connectionId);
        return const Success(unit);
      }
      return const Failure(ValidationError(message: 'Invalid connection ID'));
    }

    try {
      final success = ffi.isAsync
          ? await ffi.async.disconnect(nativeId)
          : ffi.sync.disconnect(nativeId);

      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionStrings.remove(connectionId);

      if (success) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'Failed to disconnect from database',
        nativeConnectionId: nativeId,
      );
    } on Exception catch (e, stack) {
      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
      state.connectionOptions.remove(connectionId);
      state.connectionStrings.remove(connectionId);
      return Failure<Unit, OdbcError>(
        translateOdbcError(
          e,
          operation: 'disconnect',
          stackTrace: stack,
        ),
      );
    }
  }

  bool isInitialized() =>
      ffi.isAsync ? ffi.async.isInitialized : ffi.sync.isInitialized;

  void disposeNative() {
    if (ffi.isAsync) {
      ffi.async.dispose();
    } else {
      ffi.sync.dispose();
    }
  }

  void clearAllState() => state.clearAll();

  DartSideMetrics dartSideMetrics() => state.dartSideMetrics();

  void onWorkerRecovered() {
    state.clearAll();
    AppLogger.warning(
      'OdbcRepositoryImpl cleared all Dart-side state after underlying '
      'worker pool recovery; consumers must reconnect any prior connection.',
    );
    emit(WorkerRecovered(timestamp: DateTime.now().toUtc()));
  }

  Future<Result<Unit>> reconnect(
    String connectionId,
    String connectionString,
    ConnectionOptions? options,
  ) async {
    final lifetime = state.connectionLifetimes[connectionId];
    if (lifetime == null) {
      return const Failure(ValidationError(message: 'Connection is closed'));
    }
    final poolId = state.connectionPoolId[connectionId];
    final oldId = state.connectionIds[connectionId];
    if (oldId != null) {
      final released = poolId != null
          ? (ffi.isAsync
              ? await ffi.async.poolReleaseConnection(oldId)
              : ffi.sync.poolReleaseConnection(oldId))
          : (ffi.isAsync
              ? await ffi.async.disconnect(oldId)
              : ffi.sync.disconnect(oldId));
      if (!released && poolId != null) {
        return ffi.convertNativeErrorToFailure<Unit>(
          errorFactory: odbcConnectionErrorFactory,
          fallbackMessage: 'Failed to return connection to its pool',
          nativeConnectionId: oldId,
        );
      }
      state.clearStatementMetadataForConnection(connectionId);
      state.connectionIds.remove(connectionId);
    }
    final timeoutMs = options?.loginTimeoutMs ?? 0;
    final connId = poolId != null
        ? (ffi.isAsync
            ? await ffi.async.poolGetConnection(poolId)
            : ffi.sync.poolGetConnection(poolId))
        : (ffi.isAsync
            ? await ffi.async.connect(connectionString, timeoutMs: timeoutMs)
            : (timeoutMs > 0
                ? ffi.sync.connectWithTimeout(connectionString, timeoutMs)
                : ffi.sync.connect(connectionString)));
    if (connId == 0) {
      return ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: odbcConnectionErrorFactory,
        fallbackMessage: 'Reconnect failed',
      );
    }
    if (!identical(state.connectionLifetimes[connectionId], lifetime)) {
      final released = poolId != null
          ? (ffi.isAsync
              ? await ffi.async.poolReleaseConnection(connId)
              : ffi.sync.poolReleaseConnection(connId))
          : (ffi.isAsync
              ? await ffi.async.disconnect(connId)
              : ffi.sync.disconnect(connId));
      var error =
          const ConnectionError(message: 'Connection closed during recovery');
      if (!released) {
        error = ConnectionError(
          message: error.message,
          details: const OdbcErrorDetails(
            secondaryErrors: [
              QueryError(
                message: 'Failed to release recovered connection',
                details: OdbcErrorDetails(code: OdbcErrorCode.cleanup),
              ),
            ],
          ),
        );
      }
      return Failure(error);
    }
    state.connectionIds[connectionId] = connId;
    return const Success(unit);
  }

  Future<Result<Unit>> _recover(
    String id,
    String connectionString,
    ConnectionOptions opts,
  ) {
    final existing = _recoveries[id];
    if (existing != null) return existing;
    final lifetime = state.connectionLifetimes[id];
    Future<Result<Unit>> restore() async {
      OdbcError? last;
      for (var attempt = 1;
          attempt <= opts.effectiveMaxReconnectAttempts;
          attempt++) {
        if (!identical(lifetime, state.connectionLifetimes[id])) break;
        if (attempt > 1) {
          await Future<void>.delayed(opts.effectiveReconnectBackoff);
        }
        if (!identical(lifetime, state.connectionLifetimes[id])) break;
        emit(
          AutoReconnectAttempted(
            timestamp: DateTime.now().toUtc(),
            connectionId: id,
            attempt: attempt,
            maxAttempts: opts.effectiveMaxReconnectAttempts,
          ),
        );
        final result = await OdbcErrorBoundary.run(
          'reconnect',
          () => reconnect(id, connectionString, opts),
        );
        if (result.isSuccess()) return result;
        last = normalizeOdbcError(
          result.exceptionOrNull()!,
          operation: 'reconnect',
        );
        last = last.withDetails(
          last.details.copyWith(attempt: attempt, connectionId: id),
        );
        if (!last.isRetryable) break;
      }
      return Failure(
        last ??
            const ConnectionError(message: 'Connection closed during recovery'),
      );
    }

    final future = restore();
    _recoveries[id] = future;
    return future.whenComplete(() {
      if (identical(_recoveries[id], future)) _recoveries.remove(id);
    });
  }

  Future<Result<T>> withReconnect<T extends Object>(
    String connectionId,
    Future<Result<T>> Function() operation, {
    String? sqlForSlowQueryDetection,
  }) async {
    final recovering = _recoveries[connectionId];
    if (recovering != null) await recovering;
    final stopwatch =
        sqlForSlowQueryDetection != null ? (Stopwatch()..start()) : null;
    final result = await operation();
    maybeEmitSlowQuery(
      connectionId: connectionId,
      sql: sqlForSlowQueryDetection,
      stopwatch: stopwatch,
    );
    if (result.isSuccess()) return result;
    var error = normalizeOdbcError(
      result.exceptionOrNull()!,
      operation: 'executeQuery',
    );
    if (error.category != ErrorCategory.connectionLost) return Failure(error);
    error = error.withDetails(
      error.details.copyWith(connectionId: connectionId, outcomeUnknown: true),
    );
    emit(
      ConnectionLost(
        timestamp: DateTime.now().toUtc(),
        connectionId: connectionId,
        reason: error,
      ),
    );
    if (state.hasTransaction(connectionId)) return Failure(error);
    final opts = state.connectionOptions[connectionId];
    final connectionString = state.connectionStrings[connectionId];
    if (opts == null ||
        !opts.autoReconnectOnConnectionLost ||
        connectionString == null) {
      return Failure(error);
    }
    final recovered = await _recover(connectionId, connectionString, opts);
    if (recovered.isError()) {
      return Failure(
        error.withSecondary(
          normalizeOdbcError(
            recovered.exceptionOrNull()!,
            operation: 'reconnect',
          ),
        ),
      );
    }
    if (!opts.replayQueriesAfterReconnect) return Failure(error);
    return operation();
  }
}
