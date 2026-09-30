/// Maps native BCP InternalError messages to [UnsupportedFeatureError].
library;

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:test/test.dart';

void main() {
  group('odbcBulkErrorFactory', () {
    test('should_map_unsupported_sqlstate_to_UnsupportedFeatureError', () {
      final err = odbcBulkErrorFactory(
        message: 'The operation is unavailable',
        sqlState: '0A000',
      );
      expect(err, isA<UnsupportedFeatureError>());
    });

    test('should_map_driver_capability_sqlstate_to_UnsupportedFeatureError',
        () {
      final err = odbcBulkErrorFactory(
        message: 'Native SQL Server BCP is disabled by default. '
            'Set ODBC_ENABLE_UNSTABLE_NATIVE_BCP=1 to enable',
        sqlState: 'HYC00',
      );
      expect(err, isA<UnsupportedFeatureError>());
    });

    test('should_keep_generic_bulk_failures_as_QueryError', () {
      final err = odbcBulkErrorFactory(message: 'bulk insert row mismatch');
      expect(err, isA<QueryError>());
    });
  });
}
