import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:test/test.dart';

void main() {
  group('StreamQueryRunner encoding routing', () {
    test('ResultEncoding.isColumnar is true for columnar wire layouts', () {
      expect(ResultEncoding.rowMajor.isColumnar, isFalse);
      expect(ResultEncoding.columnar.isColumnar, isTrue);
      expect(ResultEncoding.columnarCompressed.isColumnar, isTrue);
    });

    test(
      'should_read_columnarCompressed_default_from_repository_state',
      () {
        final state = OdbcRepositoryState(
          defaultResultEncoding: ResultEncoding.columnarCompressed,
        );
        expect(state.defaultResultEncoding.isColumnar, isTrue);
        expect(state.defaultResultEncoding.wireCode, equals(2));
      },
    );

    test('should_keep_row_major_default_when_unconfigured', () {
      final state = OdbcRepositoryState();
      expect(state.defaultResultEncoding, ResultEncoding.rowMajor);
    });
  });
}
