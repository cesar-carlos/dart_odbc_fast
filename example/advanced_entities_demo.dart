// Advanced entities and retry helper demo (no database required).
// Run: dart run example/advanced_entities_demo.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

void main() async {
  AppLogger.initialize();

  const preparedConfig = PreparedStatementConfig(
    maxCacheSize: 100,
    ttl: Duration(minutes: 10),
  );

  const statementOptions = StatementOptions(
    timeout: Duration(seconds: 5),
    fetchSize: 500,
    maxBufferSize: 8 * 1024 * 1024,
  );

  const pk = PrimaryKeyInfo(
    tableName: 'users',
    columnName: 'id',
    position: 1,
    constraintName: 'pk_users',
  );
  const fk = ForeignKeyInfo(
    constraintName: 'fk_orders_users',
    fromTable: 'orders',
    fromColumn: 'user_id',
    toTable: 'users',
    toColumn: 'id',
  );
  const index = IndexInfo(
    indexName: 'idx_users_email',
    tableName: 'users',
    columnName: 'email',
    isUnique: true,
  );

  AppLogger.info(
    'PreparedStatementConfig maxCacheSize=${preparedConfig.maxCacheSize} '
    'ttl=${preparedConfig.ttl}',
  );
  AppLogger.info(
    'StatementOptions timeout=${statementOptions.timeout} '
    'fetchSize=${statementOptions.fetchSize}',
  );
  AppLogger.info('PrimaryKeyInfo: ${pk.tableName}.${pk.columnName}');
  AppLogger.info('ForeignKeyInfo: ${fk.fromTable}.${fk.fromColumn}');
  AppLogger.info('IndexInfo: ${index.indexName} unique=${index.isUnique}');

  var attempt = 0;
  final retryResult = await RetryHelper.execute<String>(
    () async {
      attempt++;
      if (attempt < 3) {
        return const Failure(
          QueryError(
            message: 'Transient connection issue',
            sqlState: '08001',
          ),
        );
      }
      return const Success('retry succeeded');
    },
    const RetryOptions(
      initialDelay: Duration(milliseconds: 50),
      maxDelay: Duration(milliseconds: 200),
    ),
  );

  retryResult.fold(
    (value) => AppLogger.info('RetryHelper result: $value (attempts=$attempt)'),
    (error) => AppLogger.warning('RetryHelper failed: $error'),
  );
}
