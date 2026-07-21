import 'package:odbc_fast/application/services/i_dialect_service.dart';
import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';

/// Thin [IDialectService] over [OdbcDriverFeatures].
class OdbcDialectService implements IDialectService {
  OdbcDialectService(this._features);

  final OdbcDriverFeatures _features;

  @override
  bool get supportsDialectApi => _features.supportsApi;

  @override
  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  }) =>
      _features.buildUpsertSql(
        connectionString: connectionString,
        table: table,
        columns: columns,
        conflictColumns: conflictColumns,
        updateColumns: updateColumns,
      );

  @override
  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  }) =>
      _features.appendReturningClause(
        connectionString: connectionString,
        sql: sql,
        verb: verb,
        columns: columns,
      );

  @override
  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  }) =>
      _features.getSessionInitSql(
        connectionString: connectionString,
        options: options,
      );
}
