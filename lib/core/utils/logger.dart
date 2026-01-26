import 'package:logging/logging.dart';

/// Centralized logger for ODBC Fast
class AppLogger {
  static Logger? _logger;
  static bool _initialized = false;

  /// Initialize logging system
  /// Call this once at application startup
  static void initialize({Level level = Level.INFO}) {
    if (_initialized) return;

    Logger.root.level = level;
    Logger.root.onRecord.listen((record) {
      // Default console output
      final time = record.time.toIso8601String();
      final level = record.level.name;
      final message = record.message;
      final error = record.error != null ? ' | Error: ${record.error}' : '';
      final stackTrace =
          record.stackTrace != null ? '\n${record.stackTrace}' : '';

      print('[$time] $level: $message$error$stackTrace');
    });

    _logger = Logger('odbc_fast');
    _initialized = true;
  }

  /// Get logger instance
  static Logger get logger {
    if (!_initialized) {
      initialize();
    }
    return _logger!;
  }

  /// Shorthand for logger.info
  static void info(String message, [Object? error, StackTrace? stackTrace]) {
    logger.info(message, error, stackTrace);
  }

  /// Shorthand for logger.warning
  static void warning(String message, [Object? error, StackTrace? stackTrace]) {
    logger.warning(message, error, stackTrace);
  }

  /// Shorthand for logger.severe
  static void severe(String message, [Object? error, StackTrace? stackTrace]) {
    logger.severe(message, error, stackTrace);
  }

  /// Shorthand for logger.fine
  static void fine(String message, [Object? error, StackTrace? stackTrace]) {
    logger.fine(message, error, stackTrace);
  }

  /// Shorthand for logger.shout
  static void shout(String message, [Object? error, StackTrace? stackTrace]) {
    logger.shout(message, error, stackTrace);
  }
}
