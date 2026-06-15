import 'package:odbc_fast/application/services/i_admin_service.dart';
import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/services/i_pool_service.dart';
import 'package:odbc_fast/application/services/i_query_service.dart';
import 'package:odbc_fast/application/services/i_transaction_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_admin_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_pool_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_query_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator.dart'
    show TelemetryOdbcServiceDecorator;
import 'package:odbc_fast/application/telemetry/telemetry_odbc_transaction_decorator.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/odbc_fast.dart' show TelemetryOdbcServiceDecorator;

/// Composable factories for capability-scoped telemetry decorators.
///
/// Prefer these when a consumer depends on a narrow sub-interface
/// ([IQueryService], [IPoolService], etc.) and should not pull in the
/// full [IOdbcService] aggregate. The aggregate
/// [TelemetryOdbcServiceDecorator] remains available for backward
/// compatibility.
abstract final class TelemetryOdbcDecorators {
  TelemetryOdbcDecorators._();

  static TelemetryOdbcOperations _ops(SimpleTelemetryService telemetry) =>
      TelemetryOdbcOperations(telemetry);

  /// Wraps [service] with query-shaped telemetry.
  static IQueryService query(
    IQueryService service,
    SimpleTelemetryService telemetry,
  ) =>
      TelemetryOdbcQueryDecorator(service, _ops(telemetry));

  /// Wraps [service] with pool-shaped telemetry.
  static IPoolService pool(
    IPoolService service,
    SimpleTelemetryService telemetry,
  ) =>
      TelemetryOdbcPoolDecorator(service, _ops(telemetry));

  /// Wraps [service] with transaction-shaped telemetry.
  static ITransactionService transaction(
    ITransactionService service,
    SimpleTelemetryService telemetry,
  ) =>
      TelemetryOdbcTransactionDecorator(service, _ops(telemetry));

  /// Wraps [service] with admin / lifecycle telemetry.
  static IAdminService admin(
    IAdminService service,
    SimpleTelemetryService telemetry,
  ) =>
      TelemetryOdbcAdminDecorator(service, _ops(telemetry));
}
