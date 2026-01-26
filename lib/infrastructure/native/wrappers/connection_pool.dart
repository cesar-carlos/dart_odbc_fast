import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

/// Wrapper for connection pool operations.
///
/// Provides convenient methods to manage a connection pool including
/// getting connections, releasing them, checking health, and closing the pool.
///
/// Example:
/// ```dart
/// final pool = ConnectionPool(backend, poolId);
/// final connId = pool.getConnection();
/// // ... use connection ...
/// pool.releaseConnection(connId);
/// ```
class ConnectionPool {
  /// Creates a new [ConnectionPool] instance.
  ///
  /// The backend parameter must be a valid ODBC connection backend instance.
  /// The poolId parameter must be a valid pool identifier.
  ConnectionPool(this._backend, this._poolId);

  final OdbcConnectionBackend _backend;
  final int _poolId;

  /// The pool identifier.
  int get poolId => _poolId;

  /// Gets a connection from the pool.
  ///
  /// Returns a connection ID on success, 0 on failure.
  int getConnection() => _backend.poolGetConnection(_poolId);

  /// Releases a connection back to the pool.
  ///
  /// The [connectionId] must be a connection obtained from [getConnection].
  /// Returns true on success, false on failure.
  bool releaseConnection(int connectionId) =>
      _backend.poolReleaseConnection(connectionId);

  /// Performs a health check on the connection pool.
  ///
  /// Returns true if the pool is healthy, false otherwise.
  bool healthCheck() => _backend.poolHealthCheck(_poolId);

  /// Gets the current state of the connection pool.
  ///
  /// Returns a record with pool size and idle count, or null on failure.
  ({int size, int idle})? getState() => _backend.poolGetState(_poolId);

  /// Closes the connection pool and releases all connections.
  ///
  /// Returns true on success, false on failure.
  bool close() => _backend.poolClose(_poolId);
}
