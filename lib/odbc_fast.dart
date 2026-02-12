/// Enterprise-grade ODBC data platform for Dart with a Rust native engine.
///
/// This library provides a high-performance ODBC interface with:
/// - Clean Architecture design
/// - Native Rust engine for performance
/// - Connection pooling
/// - Streaming queries
/// - Async API for non-blocking operations
/// - Automatic retry with exponential backoff
/// - Savepoints (nested transactions)
///
/// ## Quick Start
///
/// ```dart
/// import 'package:odbc_fast/odbc_fast.dart';
///
/// void main() async {
///   final service = OdbcService();
///   await service.initialize();
///
///   final connResult = await service.connect('MyDSN');
///   await connResult.fold((connection) async {
///     await service.executeQuery(connection.id, 'SELECT * FROM users');
///     await service.disconnect(connection.id);
///   }, (error) {
///     print('Error: $error');
///   });
/// }
/// ```
///
/// ## Async API (Recommended for Flutter)
///
/// For non-blocking operations, use the async API:
///
/// ```dart
/// final locator = ServiceLocator();
/// locator.initialize(useAsync: true);
///
/// final asyncService = locator.asyncService;
/// await asyncService.initialize();
///
/// final connResult = await asyncService.connect('MyDSN');
/// // ... use asyncService for all operations
///
/// locator.shutdown(); // Call on app exit
/// ```
///
/// See [README.md](https://github.com/cesar-carlos/dart_odbc_fast) for more details.
library;

export 'application/services/odbc_service.dart';
export 'core/di/service_locator.dart';
export 'core/utils/logger.dart';
export 'domain/builders/connection_string_builder.dart';
export 'domain/entities/connection.dart';
export 'domain/entities/connection_options.dart';
export 'domain/entities/isolation_level.dart';
export 'domain/entities/odbc_metrics.dart';
export 'domain/entities/pool_state.dart';
export 'domain/entities/prepared_statement_config.dart';
export 'domain/entities/prepared_statement_metrics.dart';
export 'domain/entities/query_result.dart';
export 'domain/entities/retry_options.dart';
export 'domain/entities/schema_info.dart';
export 'domain/entities/statement_options.dart';
export 'domain/errors/odbc_error.dart';
export 'domain/errors/telemetry_error.dart';
export 'domain/helpers/retry_helper.dart';
export 'domain/repositories/itelemetry_repository.dart';
export 'domain/repositories/odbc_repository.dart';
export 'domain/services/telemetry_service.dart';
export 'domain/telemetry/entities.dart';
export 'infrastructure/native/async_native_odbc_connection.dart';
export 'infrastructure/native/errors/async_error.dart';
export 'infrastructure/native/native_odbc_connection.dart';
export 'infrastructure/native/odbc_connection_backend.dart';
export 'infrastructure/native/protocol/bulk_insert_builder.dart';
export 'infrastructure/native/protocol/param_value.dart';
export 'infrastructure/native/telemetry/opentelemetry_ffi.dart';
export 'infrastructure/native/telemetry/telemetry_buffer.dart';
export 'infrastructure/native/wrappers/catalog_query.dart';
export 'infrastructure/native/wrappers/connection_pool.dart';
export 'infrastructure/native/wrappers/prepared_statement.dart';
export 'infrastructure/native/wrappers/transaction_handle.dart';
export 'infrastructure/repositories/odbc_repository_impl.dart';
export 'infrastructure/repositories/telemetry_repository.dart';

// Async support - async_native_odbc_connection and async_error exported above
