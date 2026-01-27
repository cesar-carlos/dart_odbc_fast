import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';

/// Handles worker isolate crash and restart for async ODBC connections.
///
/// When the worker isolate crashes (e.g. uncaught exception, kill), call
/// [handleWorkerCrash] to log, dispose the broken connection, and optionally
/// re-initialize a new worker. Callers must re-establish connections after
/// restart since worker state is lost.
class WorkerCrashRecovery {
  /// Logs the crash, disposes the async connection, and re-initializes a fresh
  /// worker. All previous connection IDs are invalid after this.
  ///
  /// Use when the main isolate detects worker death (e.g. receivePort error,
  /// request timeouts). After return, the caller should re-connect and
  /// re-create any connection/pool state.
  static Future<void> handleWorkerCrash(
    AsyncNativeOdbcConnection async,
    Object error, [
    StackTrace? stackTrace,
  ]) async {
    AppLogger.severe('Worker isolate crashed: $error', error, stackTrace);
    async.dispose();
    await async.initialize();
  }
}
