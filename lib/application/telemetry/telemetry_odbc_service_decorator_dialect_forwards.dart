import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator_base.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';

/// Dialect-shaped `IOdbcService` forwards for the telemetry decorator façade.
mixin TelemetryOdbcServiceDialectForwards on TelemetryOdbcServiceDecoratorBase {
  bool get supportsDialectApi => service.supportsDialectApi;

  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  }) =>
      service.buildUpsertSql(
        connectionString: connectionString,
        table: table,
        columns: columns,
        conflictColumns: conflictColumns,
        updateColumns: updateColumns,
      );

  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  }) =>
      service.appendReturningClause(
        connectionString: connectionString,
        sql: sql,
        verb: verb,
        columns: columns,
      );

  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  }) =>
      service.getSessionInitSql(
        connectionString: connectionString,
        options: options,
      );
}
