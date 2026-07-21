import 'package:odbc_fast/infrastructure/native/driver_capabilities_v3.dart';

/// Dialect-aware SQL builders (UPSERT / RETURNING / session init).
///
/// These helpers generate SQL from a connection string without opening a
/// live connection. They wrap the native `odbc_build_upsert_sql`,
/// `odbc_append_returning_sql`, and `odbc_get_session_init_sql` FFIs.
abstract interface class IDialectService {
  /// True when the loaded native library exports the dialect capability FFIs.
  bool get supportsDialectApi;

  /// Build an UPSERT statement for the dialect implied by [connectionString].
  String? buildUpsertSql({
    required String connectionString,
    required String table,
    required List<String> columns,
    required List<String> conflictColumns,
    List<String>? updateColumns,
  });

  /// Append a RETURNING/OUTPUT clause to [sql].
  String? appendReturningClause({
    required String connectionString,
    required String sql,
    required DmlVerb verb,
    required List<String> columns,
  });

  /// Post-connect session init statements for the dialect.
  List<String>? getSessionInitSql({
    required String connectionString,
    SessionOptions? options,
  });
}
