import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/odbc_metrics.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart'
    show AsyncWorkerPoolStats;
import 'package:result_dart/result_dart.dart';

/// Administrative / lifecycle operations subset of `IOdbcService`.
///
/// Initialization, connect / disconnect, runtime metrics, and capability
/// probing — the surface a host process uses to bring the driver up,
/// keep it healthy, and tear it down. Consumers that only need
/// observability / health endpoints can depend on this interface alone.
///
/// Mirrors the signatures of the corresponding `IOdbcService` members
/// exactly so existing call sites work both ways.
abstract interface class IAdminService {
  Future<Result<void>> initialize();

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  Future<Result<void>> disconnect(String connectionId);

  Future<Result<void>> validateConnectionString(String connectionString);

  Future<Result<OdbcMetrics>> getMetrics();

  Future<Result<Map<String, Object?>>> getDriverCapabilities(
    String connectionString,
  );

  /// Returns Dart-side worker-pool statistics when the underlying
  /// connection runs in async mode (P95 latency, fallbacks to blocking,
  /// queue depth, etc.). Returns `null` in sync mode where no worker
  /// pool exists.
  ///
  /// Bridges the otherwise-internal `AsyncNativeOdbcConnection.
  /// getWorkerPoolStats()` so consumers wired to `IOdbcService` /
  /// `IAdminService` can pull observability numbers without crossing
  /// the abstraction boundary. The method is infallible by design:
  /// "stats not available" is normal in sync mode and isn't an error.
  Future<AsyncWorkerPoolStats?> getWorkerPoolStats();

  /// Broadcast stream of connection-lifecycle events emitted by the
  /// runtime (connection lost, worker recovered, pool resized, etc.).
  ///
  /// Events are best-effort observability signals — listeners do not
  /// block emission, and the stream keeps working even if no listener
  /// is attached. Pattern-match on the sealed [OdbcEvent] variants to
  /// stay forward-compatible.
  ///
  /// Example — wire events to a logger and Prometheus-style metrics:
  ///
  /// ```dart
  /// service.events.listen((e) {
  ///   switch (e) {
  ///     case ConnectionLost(:final connectionId, :final reason):
  ///       log.warning('connection lost: $connectionId — ${reason.message}');
  ///     case AutoReconnectAttempted(:final attempt, :final maxAttempts):
  ///       metrics.counter('odbc.reconnect.attempts').inc();
  ///       log.info('reconnect $attempt/$maxAttempts');
  ///     case WorkerRecovered():
  ///       metrics.counter('odbc.worker.recovered').inc();
  ///     case PoolResize(:final poolId, :final newSize):
  ///       metrics.gauge(
  ///         'odbc.pool.size',
  ///         newSize,
  ///         labels: {'poolId': '$poolId'},
  ///       );
  ///     case SlowQueryDetected(:final durationMs, :final sql):
  ///       log.warning(
  ///         'slow query (${durationMs}ms): ${sql.substring(0, 60)}',
  ///       );
  ///   }
  /// });
  /// ```
  Stream<OdbcEvent> get events;
}
