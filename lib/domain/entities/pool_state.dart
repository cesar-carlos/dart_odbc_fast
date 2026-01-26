/// Current state of a connection pool.
///
/// Provides information about the pool's size and how many connections
/// are currently idle (available for use).
///
/// Example:
/// ```dart
/// final state = await service.poolGetState(poolId);
/// print('Pool size: ${state.size}, Idle: ${state.idle}');
/// ```
class PoolState {
  /// Creates a new [PoolState] instance.
  const PoolState({required this.size, required this.idle});

  /// Total number of connections in the pool (active + idle).
  final int size;

  /// Number of connections currently idle and available for use.
  final int idle;
}
