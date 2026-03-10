import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

/// Demonstrates schema reflection capabilities for primary keys, foreign keys,
/// and indexes.
///
/// This example shows how to use the catalog API to query database metadata
/// for a specific table, including its constraints and indexes.
void main() async {
  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final native = NativeOdbcConnection();
  final repository = OdbcRepositoryImpl(native);
  final service = OdbcService(repository);
  
  try {
    // Initialize ODBC environment
    final initResult = await service.initialize();
    if (initResult.isError()) {
      print('Failed to initialize: ${initResult.exceptionOrNull()}');
      return;
    }
    
    // Connect to database
    final connectResult = await service.connect(dsn);
    
    if (connectResult.isError()) {
      print('Connection failed: ${connectResult.exceptionOrNull()}');
      return;
    }
    
    final connection = connectResult.getOrThrow();
    print('Connected: ${connection.id}\n');

    // Example table to inspect
    const tableName = 'users';
    
    // 1. List Primary Keys
    print('=== Primary Keys for "$tableName" ===');
    final pkResult = await service.catalogPrimaryKeys(connection.id, tableName);
    
    if (pkResult.isSuccess()) {
      final pkData = pkResult.getOrThrow();
      print('Columns: ${pkData.columns}');
      for (final row in pkData.rows) {
        print('  ${row.join(" | ")}');
      }
      print('');
    } else {
      print('Error: ${pkResult.exceptionOrNull()}\n');
    }
    
    // 2. List Foreign Keys
    print('=== Foreign Keys for "$tableName" ===');
    final fkResult = await service.catalogForeignKeys(connection.id, tableName);
    
    if (fkResult.isSuccess()) {
      final fkData = fkResult.getOrThrow();
      print('Columns: ${fkData.columns}');
      for (final row in fkData.rows) {
        print('  ${row.join(" | ")}');
      }
      print('');
    } else {
      print('Error: ${fkResult.exceptionOrNull()}\n');
    }
    
    // 3. List Indexes
    print('=== Indexes for "$tableName" ===');
    final idxResult = await service.catalogIndexes(connection.id, tableName);
    
    if (idxResult.isSuccess()) {
      final idxData = idxResult.getOrThrow();
      print('Columns: ${idxData.columns}');
      for (final row in idxData.rows) {
        print('  ${row.join(" | ")}');
      }
      print('');
    } else {
      print('Error: ${idxResult.exceptionOrNull()}\n');
    }
    
    // Cleanup
    await service.disconnect(connection.id);
    print('Disconnected.');
  } on Exception catch (e, stackTrace) {
    print('Unexpected error: $e');
    print(stackTrace);
  } finally {
    service.dispose();
  }
}
