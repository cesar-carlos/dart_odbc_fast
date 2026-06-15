import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:test/test.dart';

void main() {
  group('StreamColumnarRunner encoding', () {
    ResultEncoding encodingFor(OdbcRepositoryState state) =>
        state.defaultResultEncoding.isColumnar
            ? state.defaultResultEncoding
            : ResultEncoding.columnar;

    test('should_use_columnarCompressed_when_repository_default_is_compressed',
        () {
      final state = OdbcRepositoryState(
        defaultResultEncoding: ResultEncoding.columnarCompressed,
      );
      expect(encodingFor(state), ResultEncoding.columnarCompressed);
      expect(encodingFor(state).wireCode, equals(2));
    });

    test('should_fall_back_to_columnar_when_default_is_row_major', () {
      final state = OdbcRepositoryState();
      expect(encodingFor(state), ResultEncoding.columnar);
    });
  });
}
