// Schema reflection via the high-level catalog service API.
//
// Demonstrates `catalogTables`, `catalogPrimaryKeys`, `catalogForeignKeys`,
// and `catalogIndexes`. Dialect-specific SQL is resolved in the Rust native
// catalog layer before results reach Dart.
//
// Optional: set `ODBC_EXAMPLE_TABLE` to inspect a specific table name.
//
// Run: dart run example/catalog_reflection_demo.dart

import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('Failed to initialize: ${init.exceptionOrNull()}');
    return;
  }

  final connectResult = await service.connect(dsn);
  final connection = connectResult.getOrNull();
  if (connection == null) {
    AppLogger.severe('Connection failed: ${connectResult.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  AppLogger.info('Connected: ${connection.id}');

  try {
    final tableName = await _resolveSampleTable(service, connection.id);
    if (tableName == null) {
      AppLogger.warning(
        'No tables found via catalogTables; skipping PK/FK/index lookup.',
      );
      return;
    }

    AppLogger.info('Inspecting table: $tableName');
    await _logCatalog(
      'Primary Keys',
      service.catalogPrimaryKeys(connection.id, tableName),
    );
    await _logCatalog(
      'Foreign Keys',
      service.catalogForeignKeys(connection.id, tableName),
    );
    await _logCatalog(
      'Indexes',
      service.catalogIndexes(connection.id, tableName),
    );
  } finally {
    await service.disconnect(connection.id);
    locator.shutdown();
    AppLogger.info('Disconnected.');
  }
}

Future<String?> _resolveSampleTable(
  IOdbcService service,
  String connectionId,
) async {
  final preferred = Platform.environment['ODBC_EXAMPLE_TABLE'];
  if (preferred != null && preferred.isNotEmpty) {
    return preferred;
  }

  final tables = await service.catalogTables(connectionId: connectionId);
  if (tables.isError()) {
    AppLogger.warning('catalogTables unavailable: ${tables.exceptionOrNull()}');
    return 'users';
  }

  final result = tables.getOrThrow();
  if (result.isEmpty) {
    return null;
  }

  // Prefer a common sample name when present; otherwise take the first row.
  for (final row in result.rows) {
    for (final cell in row) {
      if (cell is String && cell.toLowerCase() == 'users') {
        return cell;
      }
    }
  }

  for (final row in result.rows) {
    for (final cell in row) {
      if (cell is String && cell.isNotEmpty) {
        return cell;
      }
    }
  }
  return null;
}

Future<void> _logCatalog(
  String label,
  Future<Result<QueryResult>> pending,
) async {
  AppLogger.info('=== $label ===');
  final result = await pending;
  result.fold(
    (data) {
      AppLogger.info('Columns: ${data.columns}');
      for (final row in data.rows) {
        AppLogger.info('  ${row.join(' | ')}');
      }
    },
    (error) => AppLogger.warning('Error: $error'),
  );
}
