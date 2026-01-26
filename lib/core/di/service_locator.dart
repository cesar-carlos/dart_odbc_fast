import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';

/// Dependency injection container for ODBC Fast services.
///
/// Provides a singleton instance that manages the lifecycle of core services
/// including the native ODBC connection, repository, and service layers.
///
/// Example:
/// ```dart
/// final locator = ServiceLocator();
/// locator.initialize();
/// final service = locator.service;
/// ```
class ServiceLocator {
  /// Gets the singleton instance of [ServiceLocator].
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();
  static final ServiceLocator _instance = ServiceLocator._internal();

  late final NativeOdbcConnection _nativeConnection;
  late final IOdbcRepository _repository;
  late final OdbcService _service;

  /// Initializes all services and dependencies.
  ///
  /// Must be called before accessing [service], [repository], or [nativeConnection].
  /// This method initializes logging, creates the native connection, repository,
  /// and service instances.
  void initialize() {
    // Initialize logging
    AppLogger.initialize();

    _nativeConnection = NativeOdbcConnection();
    _repository = OdbcRepositoryImpl(_nativeConnection);
    _service = OdbcService(_repository);

    AppLogger.info('ServiceLocator initialized');
  }

  /// Gets the [OdbcService] instance.
  ///
  /// Throws if [initialize] has not been called.
  OdbcService get service => _service;

  /// Gets the [IOdbcRepository] instance.
  ///
  /// Throws if [initialize] has not been called.
  IOdbcRepository get repository => _repository;

  /// Gets the [NativeOdbcConnection] instance.
  ///
  /// Throws if [initialize] has not been called.
  NativeOdbcConnection get nativeConnection => _nativeConnection;
}
