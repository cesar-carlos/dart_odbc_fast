// Connection pool with eviction/timeout options (v3.0).
// Run: dart run example/pool_with_options_demo.dart
//
// This demo does NOT require a database — it shows the typed `PoolOptions`
// JSON encoding and the `OdbcPoolFactory.createPool` helper that
// transparently falls back to the legacy `poolCreate` when either:
//   - the caller passes no options, OR
//   - the loaded native library predates the v3.0
//     `odbc_pool_create_with_options` entry point.

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/odbc_fast.dart';

void main() {
  AppLogger.initialize();

  AppLogger.info('--- PoolOptions JSON encoding -----------------------');

  const empty = PoolOptions();
  AppLogger.info(
    'Empty options       : ${empty.hasAnyOption}, json=${empty.toJson()}',
  );

  const onlyTimeout = PoolOptions(connectionTimeout: Duration(seconds: 10));
  AppLogger.info('Only acquire timeout: json=${onlyTimeout.toJson()}');

  const fullSet = PoolOptions(
    idleTimeout: Duration(minutes: 5),
    maxLifetime: Duration(hours: 1),
    connectionTimeout: Duration(seconds: 30),
  );
  AppLogger.info('All three options   : json=${fullSet.toJson()}');

  AppLogger.info('--- Runtime FFI capability detection ----------------');

  // OdbcNative loads the native library; if missing, the example skips.
  late OdbcNative native;
  try {
    native = OdbcNative();
  } on Object catch (e) {
    AppLogger.warning('Native library unavailable, skipping FFI demo: $e');
    return;
  }
  if (!native.init()) {
    AppLogger.severe('odbc_init failed');
    native.dispose();
    return;
  }

  final factory = OdbcPoolFactory(native);
  AppLogger.info(
    'Factory.supportsApi (v3.0 odbc_pool_create_with_options) = '
    '${factory.supportsApi}',
  );

  // We do not actually create a pool here (no DSN required). The factory
  // would route the call as follows:
  //
  //  - createPool(connStr, max, options: null)         -> legacy poolCreate
  //  - createPool(connStr, max, options: PoolOptions()) (empty) -> legacy
  //  - createPool(connStr, max, options: <fullSet>)
  //      -> odbc_pool_create_with_options when supportsApi == true,
  //         falls back to legacy poolCreate otherwise (warns silently).

  AppLogger.info('--- Documentation ----------------------------------');
  AppLogger.info(
    'PoolOptions encoding keys (ms): '
    'idle_timeout_ms, max_lifetime_ms, connection_timeout_ms',
  );

  native.dispose();
}
