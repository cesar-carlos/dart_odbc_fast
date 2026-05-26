import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void main() {
  group('public API exports', () {
    test('exports pool option types', () {
      const options = PoolOptions(
        connectionTimeout: Duration(seconds: 5),
      );
      expect(options.hasAnyOption, isTrue);
      expect(OdbcPoolFactory, isNotNull);
    });

    test('exports driver capability types', () {
      final capabilities = DriverCapabilities.fromJson(
        const {
          'driver_name': 'mock',
          'driver_version': '1.0',
          'engine': DatabaseEngineIds.sqlite,
        },
      );
      expect(capabilities.databaseType, DatabaseType.sqlite);

      final info = DbmsInfo.fromJson(
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
      // Both ColumnMetadata and ParsedRowBuffer must be reachable through
      // the barrel so consumers of streamQuery / streamQueryBatched and
      // CatalogQuery can name those types in their code.
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
  });
}
