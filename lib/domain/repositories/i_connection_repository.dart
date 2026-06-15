import 'package:odbc_fast/domain/entities/connection.dart';
import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:result_dart/result_dart.dart';

/// Connection lifecycle operations for the ODBC repository.
abstract interface class IConnectionRepository {
  Future<Result<Unit>> initialize();

  Future<Result<Connection>> connect(
    String connectionString, {
    ConnectionOptions? options,
  });

  Future<Result<Unit>> disconnect(String connectionId);

  bool isInitialized();

  Future<Result<Unit>> validateConnectionString(String connectionString);

  Future<String?> detectDriver(String connectionString);
}
