/// Enterprise-grade ODBC data platform for Dart with a Rust native engine.
///
/// This library provides a high-performance ODBC interface with:
/// - Clean Architecture design
/// - Native Rust engine for performance
/// - Connection pooling
/// - Streaming queries
/// - Async API for non-blocking operations
/// - Automatic reconnect on connection-lost (configurable attempts/backoff)
/// - Savepoints (nested transactions)
///
/// ## Quick Start (opt-in balanced async)
///
/// ```dart
/// import 'package:odbc_fast/core/di/service_locator.dart';
/// import 'package:odbc_fast/odbc_fast.dart';
///
/// void main() async {
///   AppLogger.initialize();
///   final locator = ServiceLocator()
///     ..initialize(profile: OdbcUsageProfile.balanced);
///   final service = locator.service;
///   final tuning = locator.resolvedUsageProfile;
///   await service.initialize();
///
///   final connResult = await service.connect(
///     'MyDSN',
///     options: locator.recommendedConnectionOptions,
///   );
///   await connResult.fold((connection) async {
///     await service.executeQuery(
///       'SELECT * FROM users',
///       connectionId: connection.id,
///     );
///     await service.disconnect(connection.id);
///   }, (error) {
///     AppLogger.severe('Error: $error');
///   });
///
///   locator.shutdown();
/// }
/// ```
///
/// ## Sync / CLI (default legacy profile)
///
/// ```dart
/// final locator = ServiceLocator()..initialize();
/// final service = locator.syncService;
/// await service.initialize();
/// // ... use syncService; no shutdown workers unless you had enabled async
/// ```
///
/// Use `OdbcUsageProfile.highThroughput` for heavier server workloads that want
/// a larger async worker pool and a larger recommended native pool size.
///
/// See [README.md](https://github.com/cesar-carlos/dart_odbc_fast) for more details.
library;

export 'application/repositories/odbc_repository_extensions.dart';
export 'application/services/i_admin_service.dart';
export 'application/services/i_dialect_service.dart';
export 'application/services/i_pool_service.dart';
export 'application/services/i_query_service.dart';
export 'application/services/i_query_service_extensions.dart';
export 'application/services/i_transaction_service.dart';
export 'application/services/odbc_service.dart';
export 'application/telemetry/telemetry_odbc_admin_decorator.dart';
export 'application/telemetry/telemetry_odbc_decorators.dart';
export 'application/telemetry/telemetry_odbc_pool_decorator.dart';
export 'application/telemetry/telemetry_odbc_query_decorator.dart';
export 'application/telemetry/telemetry_odbc_service_decorator.dart';
export 'application/telemetry/telemetry_odbc_transaction_decorator.dart';
export 'core/di/async_backpressure_mode.dart';
export 'core/di/resolved_odbc_usage_profile.dart';
export 'core/di/service_locator.dart';
export 'core/utils/logger.dart';
export 'domain/builders/connection_string_builder.dart';
export 'domain/entities/async_worker_pool_stats.dart';
export 'domain/entities/column_metadata.dart';
export 'domain/entities/connection.dart';
export 'domain/entities/connection_options.dart';
export 'domain/entities/dart_side_metrics.dart';
export 'domain/entities/directed_param.dart';
export 'domain/entities/driver_capabilities.dart';
export 'domain/entities/isolation_level.dart';
export 'domain/entities/odbc_event.dart';
export 'domain/entities/odbc_metrics.dart';
export 'domain/entities/odbc_usage_profile.dart';
export 'domain/entities/param_value.dart';
export 'domain/entities/pool_options.dart';
export 'domain/entities/pool_state.dart';
export 'domain/entities/prepared_statement_config.dart';
export 'domain/entities/query_result.dart';
export 'domain/entities/query_result_multi.dart';
export 'domain/entities/result_encoding.dart';
export 'domain/entities/retry_options.dart';
export 'domain/entities/savepoint_dialect.dart';
export 'domain/entities/schema_info.dart';
export 'domain/entities/statement_options.dart';
export 'domain/entities/transaction_access_mode.dart';
export 'domain/entities/typed_columnar_result.dart';
export 'domain/entities/xa_transaction_handle.dart';
export 'domain/entities/xid.dart';
export 'domain/errors/odbc_error.dart';
export 'domain/errors/telemetry_error.dart';
export 'domain/helpers/query_result_access.dart';
export 'domain/helpers/retry_helper.dart';
export 'domain/helpers/typed_columnar_converter.dart';
export 'domain/repositories/i_admin_repository.dart';
export 'domain/repositories/i_connection_repository.dart';
export 'domain/repositories/i_pool_repository.dart';
export 'domain/repositories/i_query_repository.dart';
export 'domain/repositories/i_transaction_repository.dart';
export 'domain/repositories/itelemetry_repository.dart';
export 'domain/repositories/odbc_repository.dart';
export 'domain/services/itelemetry_service.dart';
export 'domain/services/simple_telemetry_service.dart';
export 'domain/telemetry/entities.dart';
export 'domain/types/param_direction.dart';
export 'domain/types/sql_data_type.dart';
export 'infrastructure/native/driver_capabilities.dart';
export 'infrastructure/native/driver_capabilities_v3.dart';
export 'infrastructure/native/native_bcp_runtime.dart';
export 'infrastructure/native/odbc_connection_backend.dart';
export 'infrastructure/native/protocol/binary_protocol.dart'
    show BinaryProtocolParser, ColumnMetadata, ParsedRowBuffer;
export 'infrastructure/native/protocol/bulk_insert_builder.dart';
export 'infrastructure/native/protocol/columnar_v2_flags.dart';
export 'infrastructure/native/protocol/directed_param.dart';
export 'infrastructure/native/protocol/lazy_string.dart';
export 'infrastructure/native/protocol/multi_result_parser.dart'
    show MultiResultItem, MultiResultParser;
export 'infrastructure/native/protocol/named_parameter_parser.dart';
export 'infrastructure/native/protocol/param_value.dart'
    hide paramValuesFromObjects, toParamValue;
export 'infrastructure/native/protocol/typed_columnar_converter.dart'
    show toTypedColumnar;
export 'infrastructure/native/telemetry/telemetry_buffer.dart';
export 'infrastructure/native/wrappers/catalog_query.dart';
export 'infrastructure/native/wrappers/connection_pool.dart';
export 'infrastructure/native/wrappers/prepared_statement.dart';
export 'infrastructure/native/wrappers/transaction_handle.dart';
export 'infrastructure/native/wrappers/xa_transaction_handle.dart';
export 'infrastructure/repositories/telemetry_repository.dart';

// Native FFI, repository impl, and async_error: use
// `package:odbc_fast/odbc_fast_native.dart`.
