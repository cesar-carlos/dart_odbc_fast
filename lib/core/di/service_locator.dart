import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';

/// Dependency injection container for ODBC Fast services.
///
/// Provides a singleton instance that manages the lifecycle of core services
/// including the native ODBC connection, repository, and service layers.
///
/// ## Sync vs Async Mode
///
/// By default, operates in sync mode (blocking operations). Set `useAsync`
/// to true during initialization for non-blocking async operations, which is
/// recommended for Flutter applications to prevent UI freezing.
///
/// ## Example (Sync Mode)
/// ```dart
/// final locator = ServiceLocator();
/// locator.initialize();
/// final service = locator.service;
/// await service.initialize();
/// ```
///
/// ## Example (Async Mode - Recommended for Flutter)
/// ```dart
/// final locator = ServiceLocator();
/// locator.initialize(useAsync: true);
/// final service = locator.asyncService;
/// await service.initialize();
/// ```
///
/// See also:
/// - [AsyncNativeOdbcConnection] for non-blocking database operations
/// - [NativeOdbcConnection] for synchronous operations
class ServiceLocator {
  /// Gets the singleton instance of [ServiceLocator].
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();
  static final ServiceLocator _instance = ServiceLocator._internal();

  // Sync dependencies (existing)
  late final NativeOdbcConnection _nativeConnection;
  late final IOdbcRepository _repository;
  late final OdbcService _service;

  // Async dependencies (new)
  late final AsyncNativeOdbcConnection _asyncNativeConnection;
  late final IOdbcRepository _asyncRepository;
  late final OdbcService _asyncService;

  bool _useAsync = false;

  /// Initializes all services and dependencies.
  ///
  /// Must be called before accessing [service], [repository], or
  /// [nativeConnection].
  ///
  /// Set `useAsync` to true for non-blocking operations (recommended for
  /// Flutter). When `useAsync` is true, all database operations execute in
  /// background isolates, preventing UI freezes during long-running queries.
  ///
  /// ## Sync Mode (useAsync: false, default)
  /// - Operations are blocking but slightly faster (no isolate overhead)
  /// - Suitable for CLI tools, simple scripts, fast queries (<10ms)
  /// - Use [service] or [syncService] to access
  ///
  /// ## Async Mode (useAsync: true)
  /// - Operations are non-blocking (executed in isolates)
  /// - Required for Flutter applications
  /// - Recommended for queries >10ms or parallel operations
  /// - Use [asyncService] to access
  ///
  /// This method initializes logging, creates the native connection,
  /// repository, and service instances.
  void initialize({bool useAsync = false}) {
    _useAsync = useAsync;
    AppLogger.initialize();

    _nativeConnection = NativeOdbcConnection();
    _repository = OdbcRepositoryImpl(_nativeConnection);
    _service = OdbcService(_repository, null);

    if (useAsync) {
      _asyncNativeConnection = AsyncNativeOdbcConnection();
      _asyncRepository = OdbcRepositoryImpl(_asyncNativeConnection);
      _asyncService = OdbcService(_asyncRepository, null);
    }

    AppLogger.info('ServiceLocator initialized (async: $useAsync)');
  }

  /// Gets the appropriate service based on initialization mode.
  ///
  /// If [initialize] was called with `useAsync: true`, returns the async
  /// service. Otherwise returns the sync service.
  ///
  /// Throws if [initialize] has not been called.
  ///
  /// See also:
  /// - [syncService] - Always returns sync service
  /// - [asyncService] - Always returns async service (throws if not
  ///   initialized)
  OdbcService get service => _useAsync ? _asyncService : _service;

  /// Gets the sync [OdbcService] instance.
  ///
  /// Always available regardless of `useAsync` setting. Use this when you
  /// explicitly want blocking operations (e.g., for fast queries or CLI
  /// tools).
  ///
  /// Throws if [initialize] has not been called.
  OdbcService get syncService => _service;

  /// Gets the async [OdbcService] instance.
  ///
  /// Only available if [initialize] was called with `useAsync: true`.
  /// Use this for non-blocking database operations in Flutter apps.
  ///
  /// Throws [StateError] if [initialize] was not called with
  /// `useAsync: true`.
  OdbcService get asyncService {
    if (!_useAsync) {
      throw StateError(
        'ServiceLocator not initialized with useAsync: true. '
        'Call locator.initialize(useAsync: true) first.',
      );
    }
    return _asyncService;
  }

  /// Gets the appropriate repository based on initialization mode.
  ///
  /// If [initialize] was called with `useAsync: true`, returns the async
  /// repository. Otherwise returns the sync repository.
  ///
  /// Throws if [initialize] has not been called.
  IOdbcRepository get repository => _useAsync ? _asyncRepository : _repository;

  /// Gets the [NativeOdbcConnection] instance.
  ///
  /// This is the underlying sync connection that both sync and async modes use.
  /// The async mode wraps this connection in an [AsyncNativeOdbcConnection].
  ///
  /// Throws if [initialize] has not been called.
  NativeOdbcConnection get nativeConnection => _nativeConnection;

  /// Gets the [AsyncNativeOdbcConnection] instance.
  ///
  /// Only available if [initialize] was called with `useAsync: true`.
  /// This provides direct access to the async wrapper for advanced use cases.
  ///
  /// Throws [StateError] if [initialize] was not called with
  /// `useAsync: true`.
  AsyncNativeOdbcConnection get asyncNativeConnection {
    if (!_useAsync) {
      throw StateError(
        'ServiceLocator not initialized with useAsync: true. '
        'Call locator.initialize(useAsync: true) first.',
      );
    }
    return _asyncNativeConnection;
  }

  /// Whether the locator was initialized with async mode.
  ///
  /// Returns true if [initialize] was called with `useAsync: true`,
  /// indicating that async operations are available.
  bool get isAsyncMode => _useAsync;

  /// Releases async resources (worker isolate). Call on app exit when using
  /// async mode.
  void shutdown() {
    if (_useAsync) {
      _asyncNativeConnection.dispose();
    }
  }
}
