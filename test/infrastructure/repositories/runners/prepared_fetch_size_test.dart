import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_prepared_runner.dart';
import 'package:test/test.dart';

void main() {
  group('resolvePreparedFetchSize', () {
    test('should_keep_explicit_statement_fetch_size', () {
      expect(
        resolvePreparedFetchSize(
          statementFetchSize: 1000,
          blockFetchBatchSize: 64,
        ),
        1000,
      );
    });

    test('should_inherit_connection_batch_when_statement_fetch_is_null', () {
      expect(
        resolvePreparedFetchSize(
          statementFetchSize: null,
          blockFetchBatchSize: 64,
        ),
        64,
      );
    });

    test('should_default_to_1000_when_both_are_unset', () {
      expect(
        resolvePreparedFetchSize(
          statementFetchSize: null,
          blockFetchBatchSize: null,
        ),
        1000,
      );
    });
  });
}
