/// Maps native BCP InternalError messages to [UnsupportedFeatureError].
library;

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:test/test.dart';

void main() {
  group('odbcBulkErrorFactory', () {
    test('should_map_sqlserver_bcp_feature_message_to_UnsupportedFeatureError',
        () {
      final err = odbcBulkErrorFactory(
        message: "Enable 'sqlserver-bcp' feature for BCP support",
      );
      expect(err, isA<UnsupportedFeatureError>());
    });

    test('should_map_runtime_guard_message_to_UnsupportedFeatureError', () {
      final err = odbcBulkErrorFactory(
        message: 'Native SQL Server BCP is disabled by default. '
            'Set ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1 to enable',
      );
      expect(err, isA<UnsupportedFeatureError>());
    });

    test('should_keep_generic_bulk_failures_as_QueryError', () {
      final err = odbcBulkErrorFactory(message: 'bulk insert row mismatch');
      expect(err, isA<QueryError>());
    });
  });
}
