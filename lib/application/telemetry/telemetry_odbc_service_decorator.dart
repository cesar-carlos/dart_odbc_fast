import 'package:odbc_fast/application/services/i_admin_service.dart';
import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_pool_service.dart';
import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/application/services/i_transaction_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_decorators.dart'
    show TelemetryOdbcDecorators;
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_admin_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_pool_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_query_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_transaction_forwards.dart';
import 'package:odbc_fast/odbc_fast.dart' show TelemetryOdbcDecorators;

/// Decorator that adds telemetry to all [IOdbcService] operations.
///
/// This decorator wraps [IOdbcService] to add distributed tracing,
/// metrics collection, and event logging without modifying the core
/// service logic.
/// It follows the Decorator design pattern to separate cross-cutting concerns.
///
/// Implementation is split across capability delegates and forward mixins;
/// this class is a thin façade that composes them.
///
/// Narrow sub-interfaces are available via [queryService], [poolService],
/// [transactionService], and [adminService] for consumers that depend on
/// [IQueryService] / [IPoolService] / [ITransactionService] /
/// [IAdminService] only. Use [TelemetryOdbcDecorators] to wrap a single
/// capability without the full aggregate.
///
/// ## Usage
/// ```dart
/// final service = OdbcService(repository);
/// final telemetry = SimpleTelemetryService(repository: telemetryRepository);
/// final decoratedService = TelemetryOdbcServiceDecorator(service, telemetry);
/// final IQueryService queries = decoratedService.queryService;
/// ```
///
/// ## Features
/// - Traces all database operations with unique trace IDs
/// - Spans for each operation with timing and attributes
/// - Metrics for queries, errors, and connection counts
/// - Events for logging with severity levels
class TelemetryOdbcServiceDecorator extends TelemetryOdbcServiceDecoratorBase
    with
        TelemetryOdbcServiceAdminForwards,
        TelemetryOdbcServiceQueryForwards,
        TelemetryOdbcServiceTransactionForwards,
        TelemetryOdbcServicePoolForwards
    implements IOdbcService {
  /// Creates a new decorated ODBC service.
  ///
  /// The first parameter provides the core ODBC functionality; the second
  /// provides distributed tracing and metrics.
  TelemetryOdbcServiceDecorator(super.service, super.telemetry);

  /// Query-shaped telemetry surface ([IQueryService]).
  IQueryService get queryService => query;

  /// Pool-shaped telemetry surface ([IPoolService]).
  IPoolService get poolService => pool;

  /// Transaction-shaped telemetry surface ([ITransactionService]).
  ITransactionService get transactionService => transaction;

  /// Admin / lifecycle telemetry surface ([IAdminService]).
  IAdminService get adminService => admin;

  @override
  void dispose() => service.dispose();
}
