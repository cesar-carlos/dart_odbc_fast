import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_admin_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_pool_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_query_forwards.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_transaction_forwards.dart';

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
/// ## Usage
/// ```dart
/// final service = OdbcService(repository);
/// final telemetry = SimpleTelemetryService(repository: telemetryRepository);
/// final decoratedService = TelemetryOdbcServiceDecorator(service, telemetry);
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

  @override
  void dispose() => service.dispose();
}
