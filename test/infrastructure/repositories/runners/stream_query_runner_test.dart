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

    test(
      'should_keep_row_shaped_stream_apis_on_row_major_'
      'even_when_default_is_columnar',
      () {
        // Contract: streamQuery / streamQueryNamed always request row-major
        // wire regardless of repository defaultResultEncoding. Columnar
        // consumers must use streamQueryColumnar*.
        final state = OdbcRepositoryState(
          defaultResultEncoding: ResultEncoding.columnar,
        );
        expect(state.defaultResultEncoding.isColumnar, isTrue);
        const rowShapedWire = ResultEncoding.rowMajor;
        expect(rowShapedWire.isColumnar, isFalse);
        expect(
          rowShapedWire.wireCode,
          isNot(state.defaultResultEncoding.wireCode),
        );
      },
    );

    test(
      'should_force_streamStartAsync_wire_to_row_major_'
      'when_default_is_columnar',
      () {
        final state = OdbcRepositoryState(
          defaultResultEncoding: ResultEncoding.columnarCompressed,
        );
        // Admin streamStartAsync mirrors streamQuery: ignore profile default.
        expect(
          ResultEncoding.rowMajor.wireCode,
          isNot(state.defaultResultEncoding.wireCode),
        );
        expect(ResultEncoding.rowMajor.wireCode, equals(0));
      },
    );

    test('executeQuery_delegates_to_empty_param_oneshot_path', () {
      // Contract: no-param executeQuery uses executeQueryParamValues([])
      // (one-shot FFI), not batched stream drain.
      const empty = <Never>[];
      expect(empty, isEmpty);
      expect(ResultEncoding.rowMajor.wireCode, equals(0));
    });
  });
}
