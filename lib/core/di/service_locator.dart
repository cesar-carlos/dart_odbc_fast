import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/di/odbc_profile_async_defaults.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';

/// Dependency injection container for ODBC Fast services.
///
/// Provides a singleton instance that manages the lifecycle of core services
/// including the native ODBC connection, repository, and service layers.
///
/// ## Usage profiles
///
/// [initialize] defaults to [OdbcUsageProfile.balanced]: async mode, two
/// workers, bounded backpressure, and [recommendedConnectionOptions] /
/// [recommendedPoolOptions] tuned for reliability. Use
/// [OdbcUsageProfile.legacy] for the historical sync-only defaults, or pass
/// explicit `useAsync` / worker parameters to override profile defaults.
///
/// ## Example (balanced default — async)
/// ```dart
/// final locator = ServiceLocator()..initialize();
/// final service = locator.service;
/// await service.initialize();
///
/// final conn = await service.connect(
///   dsn,
///   options: locator.recommendedConnectionOptions,
/// );
/// ```
///
/// ## Example (Sync / CLI — legacy profile)
/// ```dart
/// final locator = ServiceLocator()
///   ..initialize(profile: OdbcUsageProfile.legacy);
/// final service = locator.syncService;
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
  late NativeOdbcConnection _nativeConnection;
  late IOdbcRepository _repository;
  late OdbcService _service;

  // Async dependencies (new)
  late AsyncNativeOdbcConnection _asyncNativeConnection;
  late IOdbcRepository _asyncRepository;
  late OdbcService _asyncService;

  bool _locatorInitialized = false;
  bool _useAsync = false;
  OdbcUsageProfile _activeProfile = OdbcUsageProfile.balanced;

  /// Active profile from the last [initialize] call.
  OdbcUsageProfile get usageProfile => _activeProfile;

  /// Connection options aligned with [usageProfile] (timeouts, reconnect).
  ConnectionOptions get recommendedConnectionOptions =>
      ConnectionOptions.fromUsageProfile(_activeProfile);

  /// Pool eviction / acquire timeouts aligned with [usageProfile].
  PoolOptions get recommendedPoolOptions =>
      PoolOptions.fromUsageProfile(_activeProfile);

  /// Suggested native pool `maxSize` for [usageProfile].
  int get recommendedPoolMaxSize => _activeProfile.recommendedPoolMaxSize;

  /// Initializes all services and dependencies.
  ///
  /// Must be called before accessing [service], [repository], or
  /// [nativeConnection].
  ///
  /// Safe to call more than once (for example in tests): a previous async
  /// worker pool is disposed before a new one is created. Call [shutdown] on
  /// app exit when using async mode so isolates are released promptly.
  ///
  /// [profile] selects async worker counts, backpressure, and the shape of
  /// [recommendedConnectionOptions] / [recommendedPoolOptions]. Omit
  /// [useAsync], [asyncWorkerCount], [asyncMaxPendingRequests], and
  /// [asyncBackpressureMode] to apply the profile defaults. Passing any of
  /// those explicitly overrides the corresponding profile value.
  void initialize({
    OdbcUsageProfile profile = OdbcUsageProfile.balanced,
    bool? useAsync,
    int? asyncWorkerCount,
    int? asyncMaxPendingRequests,
    AsyncBackpressureMode? asyncBackpressureMode,
    Duration? asyncBackpressureTimeout,
  }) {
    final preset = OdbcProfileAsyncDefaults.fromUsageProfile(profile);
    final effectiveUseAsync = useAsync ?? preset.useAsync;
    final effectiveWorkers = asyncWorkerCount ?? preset.workerCount;
    final effectiveMaxPending =
        asyncMaxPendingRequests ?? preset.maxPendingRequests;
    final effectiveBackpressureMode =
        asyncBackpressureMode ?? preset.backpressureMode;
    final effectiveBackpressureTimeout =
        asyncBackpressureTimeout ?? preset.backpressureTimeout;

    if (effectiveWorkers < 1) {
      throw ArgumentError.value(
        effectiveWorkers,
        'asyncWorkerCount',
        'must be greater than or equal to 1',
      );
    }
    if (effectiveMaxPending != null && effectiveMaxPending < 1) {
      throw ArgumentError.value(
        effectiveMaxPending,
        'asyncMaxPendingRequests',
        'must be null or greater than or equal to 1',
      );
    }
    if (effectiveBackpressureTimeout != null &&
        effectiveBackpressureTimeout < Duration.zero) {
      throw ArgumentError.value(
        effectiveBackpressureTimeout,
        'asyncBackpressureTimeout',
        'must be null, zero, or greater than zero',
      );
    }

    if (_locatorInitialized && _useAsync) {
      _asyncNativeConnection.dispose();
    }

    _activeProfile = profile;
    _useAsync = effectiveUseAsync;
    AppLogger.initialize();

    _nativeConnection = NativeOdbcConnection();
    _repository = OdbcRepositoryImpl(_nativeConnection);
    _service = OdbcService(_repository);

    if (effectiveUseAsync) {
      _asyncNativeConnection = AsyncNativeOdbcConnection(
        workerCount: effectiveWorkers,
        maxPendingRequests: effectiveMaxPending,
        backpressureMode: effectiveBackpressureMode,
        backpressureTimeout: effectiveBackpressureTimeout,
      );
      _asyncRepository = OdbcRepositoryImpl(_asyncNativeConnection);
      _asyncService = OdbcService(_asyncRepository);
    }

    AppLogger.info(
      'ServiceLocator initialized '
      '(profile: $profile, async: $effectiveUseAsync, '
      'asyncWorkerCount: $effectiveWorkers, '
      'asyncMaxPendingRequests: $effectiveMaxPending, '
      'asyncBackpressureMode: $effectiveBackpressureMode)',
    );

    _locatorInitialized = true;
  }

  /// Gets the appropriate service based on initialization mode.
  ///
  /// If [initialize] was called with async mode, returns the async
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
  /// Always available regardless of async mode. Use this when you
  /// explicitly want blocking operations (e.g., for fast queries or CLI
  /// tools).
  ///
  /// Throws if [initialize] has not been called.
  OdbcService get syncService => _service;

  /// Gets the async [OdbcService] instance.
  ///
  /// Only available if [initialize] enabled async mode.
  /// Use this for non-blocking database operations in Flutter apps.
  ///
  /// Throws [StateError] if [initialize] did not enable async.
  OdbcService get asyncService {
    if (!_useAsync) {
      throw StateError(
        'ServiceLocator not initialized with async mode. '
        'Call locator.initialize() with a non-legacy profile, or '
        'initialize(useAsync: true).',
      );
    }
    return _asyncService;
  }

  /// Gets the appropriate repository based on initialization mode.
  ///
  /// If async mode is on, returns the async repository. Otherwise returns the
  /// sync repository.
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

  /// Gets the typed native audit logger wrapper.
  ///
  /// Available after [initialize], and backed by [nativeConnection].
  OdbcAuditLogger get auditLogger => _nativeConnection.auditLogger;

  /// Gets async typed audit logger wrapper.
  ///
  /// Only available when async mode is enabled.
  AsyncOdbcAuditLogger get asyncAuditLogger {
    if (!_useAsync) {
      throw StateError(
        'ServiceLocator not initialized with async mode. '
        'Use a non-legacy profile or initialize(useAsync: true).',
      );
    }
    return AsyncOdbcAuditLogger(_asyncNativeConnection);
  }

  /// Gets the [AsyncNativeOdbcConnection] instance.
  ///
  /// Only available when async mode is enabled.
  /// This provides direct access to the async wrapper for advanced use cases.
  ///
  /// Throws [StateError] if async mode was not enabled.
  AsyncNativeOdbcConnection get asyncNativeConnection {
    if (!_useAsync) {
      throw StateError(
        'ServiceLocator not initialized with async mode. '
        'Use a non-legacy profile or initialize(useAsync: true).',
      );
    }
    return _asyncNativeConnection;
  }

  /// Whether the locator was initialized with async mode.
  bool get isAsyncMode => _useAsync;

  /// Releases async resources (worker isolate). Call on app exit when using
  /// async mode. Safe to call multiple times; subsequent [initialize] calls
  /// dispose any previous async worker automatically.
  void shutdown() {
    if (_locatorInitialized && _useAsync) {
      _asyncNativeConnection.dispose();
      _useAsync = false;
    }
  }
}
