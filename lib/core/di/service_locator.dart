import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/di/odbc_profile_async_defaults.dart';
import 'package:odbc_fast/core/di/resolved_odbc_usage_profile.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile_preset.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/audit/async_odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/audit/odbc_audit_logger.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';

export 'package:odbc_fast/application/repositories/odbc_repository_extensions.dart';
export 'package:odbc_fast/application/services/i_query_service_extensions.dart';

/// Dependency injection container for ODBC Fast services.
///
/// Provides a singleton instance that manages the lifecycle of core services
/// including the native ODBC connection, repository, and service layers.
///
/// ## Usage profiles
///
/// [initialize] defaults to [OdbcUsageProfile.legacy] to preserve the
/// historical sync-only behavior. Use [OdbcUsageProfile.balanced],
/// [OdbcUsageProfile.balancedFlutter], [OdbcUsageProfile.balancedServer], or
/// [OdbcUsageProfile.highThroughput] to opt in to async presets with bounded
/// backpressure and recommended connection / pool options. Inspect
/// [resolvedUsageProfile] to see the effective configuration after applying
/// explicit overrides.
///
/// ## Example (default sync / legacy)
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
/// ## Example (balanced async profile)
/// ```dart
/// final locator = ServiceLocator()
///   ..initialize(profile: OdbcUsageProfile.balanced);
/// final service = locator.service;
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

  // Sync dependencies — created eagerly in legacy mode; in async mode they are
  // created lazily on first access of [syncService], [nativeConnection], or
  // [auditLogger], avoiding a redundant native environment init.
  NativeOdbcConnection? _nativeConnection;
  IOdbcRepository? _repository;
  OdbcService? _service;

  // Async dependencies (new)
  late AsyncNativeOdbcConnection _asyncNativeConnection;
  late IOdbcRepository _asyncRepository;
  late OdbcService _asyncService;

  bool _locatorInitialized = false;
  bool _useAsync = false;
  OdbcUsageProfile _activeProfile = OdbcUsageProfile.legacy;
  ResolvedOdbcUsageProfile _resolvedUsageProfile =
      ResolvedOdbcUsageProfile.fromUsageProfile(OdbcUsageProfile.legacy);

  /// Preset selected in the last [initialize] call.
  OdbcUsageProfile get usageProfile => _activeProfile;

  /// Effective configuration after applying [initialize] overrides.
  ResolvedOdbcUsageProfile get resolvedUsageProfile => _resolvedUsageProfile;

  /// Connection options aligned with [resolvedUsageProfile].
  ConnectionOptions get recommendedConnectionOptions =>
      _resolvedUsageProfile.connectionOptions;

  /// Pool eviction / acquire timeouts aligned with [resolvedUsageProfile].
  PoolOptions get recommendedPoolOptions => _resolvedUsageProfile.poolOptions;

  /// Suggested native pool `maxSize` for [resolvedUsageProfile].
  int get recommendedPoolMaxSize =>
      _resolvedUsageProfile.recommendedPoolMaxSize;

  /// Suggested [ResultEncoding] for analytics SELECT workloads on
  /// [resolvedUsageProfile]. Server presets recommend columnar; pass this to
  /// `executeQueryParamValues` / async query APIs when benchmarking confirms
  /// the win for your driver and schema.
  ResultEncoding get recommendedResultEncoding =>
      _resolvedUsageProfile.recommendedResultEncoding;

  /// Initializes all services and dependencies.
  ///
  /// Must be called before accessing [service], [repository], or
  /// [nativeConnection].
  ///
  /// Safe to call more than once (for example in tests): a previous async
  /// worker pool is disposed before a new one is created. Call [shutdown] on
  /// app exit when using async mode so isolates are released promptly.
  ///
  /// [profile] selects async worker counts, backpressure, and the shape of the
  /// recommended connection and pool options. Omit [useAsync],
  /// [asyncWorkerCount], [asyncMaxPendingRequests], and
  /// [asyncBackpressureMode] to apply the profile defaults. Passing any of
  /// those explicitly overrides the corresponding async setting while
  /// [resolvedUsageProfile] keeps the effective result observable.
  void initialize({
    OdbcUsageProfile profile = OdbcUsageProfile.legacy,
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

    if (_locatorInitialized) {
      if (_useAsync) {
        _asyncNativeConnection.dispose();
      }
      // Only dispose if the sync stack was actually created.
      _nativeConnection?.dispose();
      _nativeConnection = null;
      _repository = null;
      _service = null;
    }

    final resolvedUsageProfile = ResolvedOdbcUsageProfile(
      profile: profile,
      useAsync: effectiveUseAsync,
      workerCount: effectiveWorkers,
      maxPendingRequests: effectiveMaxPending,
      backpressureMode: effectiveBackpressureMode,
      backpressureTimeout: effectiveBackpressureTimeout,
      connectionOptions: ConnectionOptions.fromUsageProfile(profile),
      poolOptions: PoolOptions.fromUsageProfile(profile),
      recommendedPoolMaxSize: profile.recommendedPoolMaxSize,
      recommendedResultEncoding:
          resolveOdbcUsageProfilePreset(profile).recommendedResultEncoding,
    );

    _activeProfile = profile;
    _resolvedUsageProfile = resolvedUsageProfile;
    _useAsync = resolvedUsageProfile.useAsync;
    AppLogger.initialize();

    if (!resolvedUsageProfile.useAsync) {
      // Eagerly create the sync stack for legacy / non-async mode so that
      // [service] and [syncService] are immediately available without extra
      // guards. In async mode the sync stack is created lazily on first access.
      _ensureSyncStack();
    }

    if (resolvedUsageProfile.useAsync) {
      _asyncNativeConnection = AsyncNativeOdbcConnection(
        workerCount: resolvedUsageProfile.workerCount,
        maxPendingRequests: resolvedUsageProfile.maxPendingRequests,
        backpressureMode: resolvedUsageProfile.backpressureMode,
        backpressureTimeout: resolvedUsageProfile.backpressureTimeout,
      );
      _asyncRepository = OdbcRepositoryImpl(_asyncNativeConnection);
      _asyncService = OdbcService(_asyncRepository);
    }

    AppLogger.info(
      'ServiceLocator initialized '
      '(profile: $profile, async: ${resolvedUsageProfile.useAsync}, '
      'asyncWorkerCount: ${resolvedUsageProfile.workerCount}, '
      'asyncMaxPendingRequests: ${resolvedUsageProfile.maxPendingRequests}, '
      'asyncBackpressureMode: ${resolvedUsageProfile.backpressureMode})',
    );

    _locatorInitialized = true;
  }

  void _requireInitialized() {
    if (!_locatorInitialized) {
      throw StateError(
        'ServiceLocator has not been initialized. '
        'Call ServiceLocator().initialize() before accessing services.',
      );
    }
  }

  // Creates the sync stack on demand. Safe to call multiple times; subsequent
  // calls are no-ops once _nativeConnection is non-null.
  void _ensureSyncStack() {
    if (_nativeConnection != null) return;
    final conn = NativeOdbcConnection();
    _nativeConnection = conn;
    final repo = OdbcRepositoryImpl(conn);
    _repository = repo;
    _service = OdbcService(repo);
  }

  /// Gets the appropriate service based on initialization mode.
  ///
  /// If [initialize] was called with async mode, returns the async
  /// service. Otherwise returns the sync service.
  ///
  /// Throws [StateError] if [initialize] has not been called.
  ///
  /// See also:
  /// - [syncService] - Always returns sync service
  /// - [asyncService] - Always returns async service (throws if not
  ///   initialized)
  OdbcService get service {
    _requireInitialized();
    if (_useAsync) return _asyncService;
    _ensureSyncStack();
    return _service!;
  }

  /// Gets the sync [OdbcService] instance.
  ///
  /// Always available regardless of async mode. Use this when you
  /// explicitly want blocking operations (e.g., for fast queries or CLI
  /// tools).
  ///
  /// Throws [StateError] if [initialize] has not been called.
  OdbcService get syncService {
    _requireInitialized();
    _ensureSyncStack();
    return _service!;
  }

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
  /// Throws [StateError] if [initialize] has not been called.
  IOdbcRepository get repository {
    _requireInitialized();
    if (_useAsync) return _asyncRepository;
    _ensureSyncStack();
    return _repository!;
  }

  /// Gets the [NativeOdbcConnection] instance.
  ///
  /// This is the underlying sync connection that both sync and async modes use.
  /// The async mode wraps this connection in an [AsyncNativeOdbcConnection].
  /// In async mode the sync stack is created lazily on first access.
  ///
  /// Throws [StateError] if [initialize] has not been called.
  NativeOdbcConnection get nativeConnection {
    _requireInitialized();
    _ensureSyncStack();
    return _nativeConnection!;
  }

  /// Gets the typed native audit logger wrapper.
  ///
  /// Available after [initialize], and backed by [nativeConnection].
  OdbcAuditLogger get auditLogger {
    _requireInitialized();
    _ensureSyncStack();
    return _nativeConnection!.auditLogger;
  }

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

  /// Releases all native resources and worker isolates. Call on app exit.
  ///
  /// Safe to call multiple times; subsequent [initialize] calls dispose any
  /// previous resources automatically.
  void shutdown() {
    if (_locatorInitialized) {
      if (_useAsync) {
        _asyncNativeConnection.dispose();
        _useAsync = false;
      }
      // Only dispose sync stack if it was actually created.
      _nativeConnection?.dispose();
      _nativeConnection = null;
      _repository = null;
      _service = null;
    }
  }
}
