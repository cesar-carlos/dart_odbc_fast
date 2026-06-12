import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcRepositoryState.defaultResultEncoding', () {
    test('should_default_to_row_major_when_unconfigured', () {
      final state = OdbcRepositoryState();
      expect(state.defaultResultEncoding, ResultEncoding.rowMajor);
    });

    test('should_accept_columnar_default_when_constructed', () {
      final state = OdbcRepositoryState(
        defaultResultEncoding: ResultEncoding.columnar,
      );
      expect(state.defaultResultEncoding, ResultEncoding.columnar);
    });
  });
}
