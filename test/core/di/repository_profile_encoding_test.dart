import 'package:odbc_fast/core/di/service_locator.dart';
import 'package:odbc_fast/domain/entities/odbc_usage_profile.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceLocator repository defaultResultEncoding', () {
    test('should_wire_row_major_for_legacy_profile', () {
      final locator = ServiceLocator()..initialize();
      final repo = locator.repository as OdbcRepositoryImpl;
      expect(repo.defaultResultEncoding, ResultEncoding.rowMajor);
      locator.shutdown();
    });

    test('should_wire_columnar_for_balanced_server_profile', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balancedServer);
      final repo = locator.repository as OdbcRepositoryImpl;
      expect(repo.defaultResultEncoding, ResultEncoding.columnar);
      expect(locator.recommendedResultEncoding, ResultEncoding.columnar);
      locator.shutdown();
    });

    test('should_wire_columnar_for_high_throughput_profile', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.highThroughput);
      final repo = locator.repository as OdbcRepositoryImpl;
      expect(repo.defaultResultEncoding, ResultEncoding.columnar);
      locator.shutdown();
    });

    test('should_wire_row_major_for_balanced_flutter_profile', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balancedFlutter);
      final repo = locator.repository as OdbcRepositoryImpl;
      expect(repo.defaultResultEncoding, ResultEncoding.rowMajor);
      locator.shutdown();
    });

    test('should_update_sync_repository_default_on_reinitialize', () {
      final locator = ServiceLocator()
        ..initialize(profile: OdbcUsageProfile.balancedServer)
        ..initialize();
      final repo = locator.repository as OdbcRepositoryImpl;
      expect(repo.defaultResultEncoding, ResultEncoding.rowMajor);
      locator.shutdown();
    });
  });
}
