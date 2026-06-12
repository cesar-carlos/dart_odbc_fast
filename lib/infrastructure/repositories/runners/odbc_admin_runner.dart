import 'dart:convert';

import 'package:odbc_fast/domain/entities/async_worker_pool_stats.dart'
    show AsyncWorkerPoolStats;
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:result_dart/result_dart.dart';

/// Metrics, audit, capabilities, and metadata-cache operations.
class OdbcAdminRunner {
  OdbcAdminRunner({
    required this.ffi,
    required this.state,
  });

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;

  Future<Result<OdbcMetrics>> getMetrics() async {
    try {
      if (ffi.isAsync) {
        final m = await ffi.async.getMetrics();
        if (m == null) {
          return await ffi.convertNativeErrorToFailure<OdbcMetrics>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get metrics',
          );
        }
        return Success(m);
      } else {
        final m = ffi.sync.getMetrics();
        if (m == null) {
          return await ffi.convertNativeErrorToFailure<OdbcMetrics>(
            errorFactory: ({required message, sqlState, nativeCode}) =>
                QueryError(
              message: message,
              sqlState: sqlState,
              nativeCode: nativeCode,
            ),
            fallbackMessage: 'Failed to get metrics',
          );
        }
        // Sync backend returns infrastructure OdbcMetrics, convert to domain
        final infraMetrics = m;
        return Success(
          OdbcMetrics(
            queryCount: infraMetrics.queryCount,
            errorCount: infraMetrics.errorCount,
            uptimeSecs: infraMetrics.uptimeSecs,
            totalLatencyMillis: infraMetrics.totalLatencyMillis,
            avgLatencyMillis: infraMetrics.avgLatencyMillis,
          ),
        );
      }
    } on Exception catch (e) {
      return Failure<OdbcMetrics, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<AsyncWorkerPoolStats>> getAsyncWorkerPoolStats() async {
    if (!ffi.isAsync) {
      return const Failure(
        UnsupportedFeatureError(
          message: 'Async worker-pool stats require async native backend',
        ),
      );
    }

    return Success(
      ffi.async.getWorkerPoolStats(),
    );
  }

  Future<AsyncWorkerPoolStats?> getWorkerPoolStats() async {
    return switch (ffi.backend) {
      SyncBackend() => null,
      AsyncBackend(:final connection) => connection.getWorkerPoolStats(),
    };
  }

  Future<Result<Map<String, String>>> getVersion() async {
    try {
      final version =
          ffi.isAsync ? await ffi.async.getVersion() : ffi.sync.getVersion();
      if (version == null ||
          (version['api'] ?? '').isEmpty && (version['abi'] ?? '').isEmpty) {
        return await ffi.convertNativeErrorToFailure<Map<String, String>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              QueryError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to get native engine version',
        );
      }
      return Success(version);
    } on Exception catch (e) {
      return Failure<Map<String, String>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> validateConnectionString(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    try {
      final validationError = ffi.isAsync
          ? await ffi.async.validateConnectionString(connectionString)
          : ffi.sync.validateConnectionString(connectionString);
      if (validationError == null || validationError.trim().isEmpty) {
        return const Success(unit);
      }
      return Failure<Unit, OdbcError>(
        ValidationError(message: validationError),
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        ValidationError(message: e.toString()),
      );
    }
  }

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  ) async {
    if (connectionString.trim().isEmpty) {
      return const Failure<Map<String, Object?>, OdbcError>(
        ValidationError(message: 'Connection string cannot be empty'),
      );
    }
    try {
      final payload = ffi.isAsync
          ? await ffi.async.getDriverCapabilitiesJson(connectionString)
          : ffi.sync.getDriverCapabilitiesJson(connectionString);

      if (payload == null || payload.isEmpty) {
        return await ffi.convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Driver capabilities API is unavailable',
        );
      }

      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid driver capabilities payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid driver capabilities JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<DbmsInfo>> getConnectionDbmsInfo(String connectionId) async {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      return const Failure<DbmsInfo, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
    }

    try {
      final payload = ffi.isAsync
          ? await ffi.async.getConnectionDbmsInfoJson(nativeId)
          : ffi.sync.getConnectionDbmsInfoJson(nativeId);

      if (payload == null || payload.isEmpty) {
        return await ffi.convertNativeErrorToFailure<DbmsInfo>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Connection DBMS info API is unavailable',
        );
      }

      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<DbmsInfo, OdbcError>(
          QueryError(message: 'Invalid connection DBMS info payload format'),
        );
      }
      return Success(DbmsInfo.fromJson(decoded));
    } on FormatException catch (e) {
      return Failure<DbmsInfo, OdbcError>(
        QueryError(message: 'Invalid connection DBMS info JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<DbmsInfo, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> setLogLevel(int level) async {
    if (level < 0 || level > 5) {
      return const Failure<Unit, OdbcError>(
        ValidationError(message: 'Log level must be between 0 and 5'),
      );
    }
    try {
      if (ffi.isAsync) {
        await ffi.async.setLogLevel(level);
      } else {
        ffi.sync.setLogLevel(level);
      }
      return const Success(unit);
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> setAuditEnabled({required bool enabled}) async {
    try {
      final ok = ffi.isAsync
          ? await ffi.async.setAuditEnabled(enabled: enabled)
          : ffi.sync.setAuditEnabled(enabled: enabled);
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to update audit state',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<Result<Map<String, Object?>>> getAuditStatus() async {
    try {
      final payload = ffi.isAsync
          ? await ffi.async.getAuditStatusJson()
          : ffi.sync.getAuditStatusJson();
      if (payload == null || payload.isEmpty) {
        return await ffi.convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read audit status',
        );
      }
      final decoded = _decodeJsonMap(payload);
      if (decoded == null) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid audit status payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid audit status JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<List<Map<String, Object?>>>> getAuditEvents({
    int limit = 0,
  }) async {
    try {
      final payload = ffi.isAsync
          ? await ffi.async.getAuditEventsJson(limit: limit)
          : ffi.sync.getAuditEventsJson(limit: limit);
      if (payload == null || payload.isEmpty) {
        return await ffi
            .convertNativeErrorToFailure<List<Map<String, Object?>>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read audit events',
        );
      }
      final decoded = _decodeJsonMapList(payload);
      if (decoded == null) {
        return const Failure<List<Map<String, Object?>>, OdbcError>(
          QueryError(message: 'Invalid audit events payload format'),
        );
      }
      return Success(decoded);
    } on FormatException catch (e) {
      return Failure<List<Map<String, Object?>>, OdbcError>(
        QueryError(message: 'Invalid audit events JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<List<Map<String, Object?>>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> clearAuditEvents() async {
    try {
      final ok = ffi.isAsync
          ? await ffi.async.clearAuditEvents()
          : ffi.sync.clearAuditEvents();
      if (ok) {
        return const Success(unit);
      }
      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to clear audit events',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> metadataCacheEnable({
    required int maxEntries,
    required int ttlSeconds,
  }) async {
    if (maxEntries <= 0 || ttlSeconds <= 0) {
      return const Failure<Unit, OdbcError>(
        ValidationError(
          message: 'maxEntries and ttlSeconds must be greater than zero',
        ),
      );
    }

    if (!ffi.isAsync && !ffi.sync.supportsMetadataCacheApi) {
      return const Failure<Unit, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final enabled = ffi.isAsync
          ? await ffi.async.metadataCacheEnable(
              maxEntries: maxEntries,
              ttlSeconds: ttlSeconds,
            )
          : ffi.sync.metadataCacheEnable(
              maxEntries: maxEntries,
              ttlSeconds: ttlSeconds,
            );

      if (enabled) {
        return const Success(unit);
      }

      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to enable metadata cache',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<Result<Map<String, Object?>>> metadataCacheStats() async {
    if (!ffi.isAsync && !ffi.sync.supportsMetadataCacheApi) {
      return const Failure<Map<String, Object?>, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final payload = ffi.isAsync
          ? await ffi.async.getMetadataCacheStatsJson()
          : ffi.sync.getMetadataCacheStatsJson();

      if (payload == null || payload.isEmpty) {
        return await ffi.convertNativeErrorToFailure<Map<String, Object?>>(
          errorFactory: ({required message, sqlState, nativeCode}) =>
              UnsupportedFeatureError(
            message: message,
            sqlState: sqlState,
            nativeCode: nativeCode,
          ),
          fallbackMessage: 'Failed to read metadata cache stats',
        );
      }

      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return const Failure<Map<String, Object?>, OdbcError>(
          QueryError(message: 'Invalid metadata cache stats payload format'),
        );
      }

      return Success(
        decoded.map<String, Object?>(
          MapEntry<String, Object?>.new,
        ),
      );
    } on FormatException catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: 'Invalid metadata cache stats JSON: ${e.message}'),
      );
    } on Exception catch (e) {
      return Failure<Map<String, Object?>, OdbcError>(
        QueryError(message: e.toString()),
      );
    }
  }

  Future<Result<Unit>> clearMetadataCache() async {
    if (!ffi.isAsync && !ffi.sync.supportsMetadataCacheApi) {
      return const Failure<Unit, OdbcError>(
        UnsupportedFeatureError(
          message: 'Metadata cache API is not available in native runtime',
        ),
      );
    }

    try {
      final cleared = ffi.isAsync
          ? await ffi.async.clearMetadataCache()
          : ffi.sync.clearMetadataCache();

      if (cleared) {
        return const Success(unit);
      }

      return await ffi.convertNativeErrorToFailure<Unit>(
        errorFactory: ({required message, sqlState, nativeCode}) =>
            UnsupportedFeatureError(
          message: message,
          sqlState: sqlState,
          nativeCode: nativeCode,
        ),
        fallbackMessage: 'Failed to clear metadata cache',
      );
    } on Exception catch (e) {
      return Failure<Unit, OdbcError>(
        UnsupportedFeatureError(message: e.toString()),
      );
    }
  }

  Future<String?> detectDriver(String connectionString) async {
    if (connectionString.trim().isEmpty) {
      return null;
    }
    return ffi.isAsync
        ? await ffi.async.detectDriver(connectionString)
        : ffi.sync.detectDriver(connectionString);
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

  List<Map<String, Object?>>? _decodeJsonMapList(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! List<dynamic>) {
      return null;
    }
    final items = <Map<String, Object?>>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        return null;
      }
      items.add(
        item.map<String, Object?>(
          MapEntry<String, Object?>.new,
        ),
      );
    }
    return items;
  }
}
