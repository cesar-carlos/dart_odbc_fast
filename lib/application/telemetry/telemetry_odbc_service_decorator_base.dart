import 'package:odbc_fast/application/services/i_odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_admin_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_operations.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_pool_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_query_decorator.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_transaction_decorator.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';

/// Shared delegate wiring for `TelemetryOdbcServiceDecorator` forward mixins.
abstract class TelemetryOdbcServiceDecoratorBase {
  /// Creates capability delegates for telemetry forwarding mixins.
  TelemetryOdbcServiceDecoratorBase(this.service, this.telemetry) {
    final ops = TelemetryOdbcOperations(telemetry);
    admin = TelemetryOdbcAdminDecorator(service, ops);
    query = TelemetryOdbcQueryDecorator(service, ops);
    pool = TelemetryOdbcPoolDecorator(service, ops);
    transaction = TelemetryOdbcTransactionDecorator(service, ops);
  }

  /// Underlying service (used for lifecycle forwarding).
  final IOdbcService service;

  /// Telemetry sink wired into capability delegates.
  final SimpleTelemetryService telemetry;

  /// Admin-shaped telemetry delegate.
  late final TelemetryOdbcAdminDecorator admin;

  /// Query-shaped telemetry delegate.
  late final TelemetryOdbcQueryDecorator query;

  /// Pool-shaped telemetry delegate.
  late final TelemetryOdbcPoolDecorator pool;

  /// Transaction-shaped telemetry delegate.
  late final TelemetryOdbcTransactionDecorator transaction;
}
