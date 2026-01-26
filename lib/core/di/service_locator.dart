import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:odbc_fast/domain/repositories/odbc_repository.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';

class ServiceLocator {
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();
  static final ServiceLocator _instance = ServiceLocator._internal();

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
