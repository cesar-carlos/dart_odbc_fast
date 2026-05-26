import 'package:odbc_fast/domain/errors/odbc_error.dart';

/// Connection-lifecycle events emitted by the package's
/// `IAdminService` event bus (`Stream<OdbcEvent>`). Sealed so consumers
/// can pattern-match exhaustively and the surface stays stable across
/// additive changes.
///
/// Events are best-effort observability signals: the package keeps
/// working if no listener is attached, and there's no back-pressure
/// from listeners onto the runtime path that emits them. The default
/// Stream is broadcast (multi-listener safe).
///
/// Variants:
/// - [ConnectionLost] — `_withReconnect` detected a dropped connection.
/// - [WorkerRecovered] — async worker pool re-spun after a crash.
/// - [AutoReconnectAttempted] — `_withReconnect` re-issued a request.
/// - [PoolResize] — `poolSetSize` changed pool capacity.
/// - [SlowQueryDetected] — query duration crossed the configured
///   threshold (or the connection's `queryTimeout`).
sealed class OdbcEvent {
  /// Common base. Stamps every event with a UTC timestamp.
  const OdbcEvent(this.timestamp);

  /// UTC time when the event was emitted by the runtime.
  final DateTime timestamp;
}

/// Emitted when `_withReconnect` notices the underlying ODBC connection
/// has dropped (network error, server restart, idle timeout, etc.).
/// The runtime may follow this with [AutoReconnectAttempted] events
/// when auto-reconnect is enabled.
final class ConnectionLost extends OdbcEvent {
  const ConnectionLost({
    required DateTime timestamp,
    required this.connectionId,
    required this.reason,
  }) : super(timestamp);

  /// Domain-side connection id that was lost.
  final String connectionId;

  /// Typed reason why the connection was considered lost.
  final OdbcError reason;

  @override
  String toString() => 'ConnectionLost(connectionId: $connectionId, '
      'reason: ${reason.runtimeType}, timestamp: $timestamp)';
}

/// Emitted after the async worker pool finishes recovering from a
/// crashed worker. Repository state (per-connection ids, pool checkouts,
/// statement metadata) has already been wiped at this point — consumers
/// may need to reconnect.
final class WorkerRecovered extends OdbcEvent {
  const WorkerRecovered({required DateTime timestamp}) : super(timestamp);

  @override
  String toString() => 'WorkerRecovered(timestamp: $timestamp)';
}

/// Emitted each time `_withReconnect` retries a failed call after a
/// transient connection error. [attempt] is 1-based; [maxAttempts]
/// reflects the policy in effect.
final class AutoReconnectAttempted extends OdbcEvent {
  const AutoReconnectAttempted({
    required DateTime timestamp,
    required this.connectionId,
    required this.attempt,
    required this.maxAttempts,
  }) : super(timestamp);

  /// Domain-side connection id being retried.
  final String connectionId;

  /// 1-based attempt counter.
  final int attempt;

  /// Total attempts allowed by the active policy.
  final int maxAttempts;

  @override
  String toString() => 'AutoReconnectAttempted(connectionId: $connectionId, '
      'attempt: $attempt/$maxAttempts, timestamp: $timestamp)';
}

/// Emitted by `poolSetSize` after a successful capacity change. Useful
/// for dashboards that track pool elasticity over time.
final class PoolResize extends OdbcEvent {
  const PoolResize({
    required DateTime timestamp,
    required this.poolId,
    required this.oldSize,
    required this.newSize,
  }) : super(timestamp);

  /// Native pool id whose size changed.
  final int poolId;

  /// Capacity before the resize.
  final int oldSize;

  /// Capacity after the resize.
  final int newSize;

  @override
  String toString() => 'PoolResize(poolId: $poolId, '
      '$oldSize -> $newSize, timestamp: $timestamp)';
}

/// Emitted when a query's wall-clock duration crosses the configured
/// slow-query threshold (or the connection's `queryTimeout`).
/// Threshold and emission policy are infrastructure concerns; the
/// event itself is a pure observability signal.
final class SlowQueryDetected extends OdbcEvent {
  const SlowQueryDetected({
    required DateTime timestamp,
    required this.connectionId,
    required this.sql,
    required this.durationMs,
  }) : super(timestamp);

  /// Domain-side connection id where the query ran.
  final String connectionId;

  /// SQL text (already redacted of bound parameter values, per the
  /// upstream redaction policy).
  final String sql;

  /// Wall-clock duration measured by the package.
  final int durationMs;

  @override
  String toString() {
    final preview = sql.length > 80 ? '${sql.substring(0, 77)}...' : sql;
    return 'SlowQueryDetected(connectionId: $connectionId, '
        'duration: ${durationMs}ms, sql: "$preview", timestamp: $timestamp)';
  }
}
