import 'package:odbc_fast/infrastructure/native/odbc_connection_backend.dart';

class ConnectionPool {
  ConnectionPool(this._backend, this._poolId);

  final OdbcConnectionBackend _backend;
  final int _poolId;

  int get poolId => _poolId;

  int getConnection() => _backend.poolGetConnection(_poolId);

  bool releaseConnection(int connectionId) =>
      _backend.poolReleaseConnection(connectionId);

  bool healthCheck() => _backend.poolHealthCheck(_poolId);

  ({int size, int idle})? getState() => _backend.poolGetState(_poolId);

  bool close() => _backend.poolClose(_poolId);
}
