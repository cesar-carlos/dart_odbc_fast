import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

void main() {
  group('public API exports', () {
    test('exports domain pool option types', () {
      const options = PoolOptions(
        connectionTimeout: Duration(seconds: 5),
      );
      expect(options.hasAnyOption, isTrue);
    });

    test('exports native pool factory via odbc_fast_native', () {
      expect(OdbcPoolFactory, isNotNull);
    });

    test('exports driver capability domain types', () {
      const capabilities = DriverCapabilities(
        supportsPreparedStatements: true,
        supportsBatchOperations: true,
        supportsStreaming: true,
        maxRowArraySize: 1000,
        driverName: 'mock',
        driverVersion: '1.0',
        databaseType: DatabaseType.sqlite,
        engineId: DatabaseEngineIds.sqlite,
        supportsNativeBcp: false,
      );
      expect(capabilities.databaseType, DatabaseType.sqlite);

      final parsed = DriverCapabilitiesMapper.fromJson(
        const {
          'driver_name': 'mock',
          'driver_version': '1.0',
          'engine': DatabaseEngineIds.sqlite,
        },
      );
      expect(parsed.databaseType, DatabaseType.sqlite);

      final info = DriverCapabilitiesMapper.dbmsInfoFromJson(
        const {
          'dbms_name': 'SQLite',
          'engine': DatabaseEngineIds.sqlite,
        },
      );
      expect(info.databaseType, DatabaseType.sqlite);
    });

    test('exports usage profile and profile factories', () {
      expect(OdbcUsageProfile.balanced.recommendedPoolMaxSize, 4);
      expect(OdbcUsageProfile.balancedServer.recommendedPoolMaxSize, 8);
      expect(OdbcUsageProfile.highThroughput.recommendedPoolMaxSize, 12);
      final conn =
          ConnectionOptions.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(conn.queryTimeout, const Duration(seconds: 120));
      final pool = PoolOptions.fromUsageProfile(OdbcUsageProfile.balanced);
      expect(pool.hasAnyOption, isTrue);
      final resolved = ResolvedOdbcUsageProfile.fromUsageProfile(
        OdbcUsageProfile.highThroughput,
      );
      expect(resolved.workerCount, 6);
      expect(resolved.maxPendingRequests, 48);
    });

    test('exports driver feature helper types', () {
      expect(DmlVerb.insert.code, equals(0));
      expect(const SessionOptions().toJson(), isEmpty);
      expect(OdbcDriverFeatures, isNotNull);
    });

    test('exports parsed row buffer types for catalog/streaming consumers', () {
      const meta = ColumnMetadata(name: 'id', odbcType: 1);
      expect(meta.name, equals('id'));

      final buf = ParsedRowBuffer(
        columns: const [meta],
        rows: const [
          [1],
        ],
        rowCount: 1,
        columnCount: 1,
      );
      expect(buf.columnNames, orderedEquals(['id']));
    });

    test('exports segregated repository contracts', () {
      expect(
        IQueryRepository,
        isNotNull,
        reason: 'segregated query repository contract',
      );
      expect(
        IPoolRepository,
        isNotNull,
        reason: 'segregated pool repository contract',
      );
      expect(
        IAdminRepository,
        isNotNull,
        reason: 'segregated admin repository contract',
      );
      expect(
        ITransactionRepository,
        isNotNull,
        reason: 'segregated transaction repository contract',
      );
      expect(
        IConnectionRepository,
        isNotNull,
        reason: 'segregated connection repository contract',
      );
    });

    test('exports transaction and XA symbols', () {
      expect(IsolationLevel.readCommitted, isNotNull);
      expect(SavepointDialect.auto, isNotNull);
      expect(TransactionAccessMode.readWrite, isNotNull);
      expect(XaState.active, isNotNull);

      final xid = Xid(
        formatId: 0,
        gtrid: Uint8List.fromList([1, 2, 3]),
      );
      expect(xid.formatId, 0);
    });

    test('exports bulk insert builder', () {
      final builder = BulkInsertBuilder()
        ..table('users')
        ..addColumn('id', BulkColumnType.i32);
      expect(builder.tableName, 'users');
    });

    test('exports async error types via odbc_fast_native', () {
      expect(AsyncErrorCode.requestTimeout, isNotNull);
      const error = AsyncError(
        code: AsyncErrorCode.queryFailed,
        message: 'test',
      );
      expect(error.message, 'test');
    });
  });
}
