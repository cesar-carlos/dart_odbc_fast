import '../../domain/repositories/odbc_repository.dart';
import '../../infrastructure/native/native_odbc_connection.dart';
import '../../infrastructure/repositories/odbc_repository_impl.dart';
import '../../application/services/odbc_service.dart';
import '../utils/logger.dart';

class ServiceLocator {
  static final ServiceLocator _instance = ServiceLocator._internal();
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();

  late final NativeOdbcConnection _nativeConnection;
  late final IOdbcRepository _repository;
  late final OdbcService _service;

  void initialize() {
    // Initialize logging
    AppLogger.initialize();

    _nativeConnection = NativeOdbcConnection();
    _repository = OdbcRepositoryImpl(_nativeConnection);
    _service = OdbcService(_repository);

    AppLogger.info('ServiceLocator initialized');
  }

  OdbcService get service => _service;
  IOdbcRepository get repository => _repository;
  NativeOdbcConnection get nativeConnection => _nativeConnection;
}
