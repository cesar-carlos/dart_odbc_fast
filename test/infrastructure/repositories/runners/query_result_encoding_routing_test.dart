import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:test/test.dart';

void main() {
  group('forQueryResultWire', () {
    test('should_return_row_major_when_requested_is_null', () {
      expect(forQueryResultWire(null), ResultEncoding.rowMajor);
    });

    test('should_return_row_major_when_requested_is_row_major', () {
      expect(
        forQueryResultWire(ResultEncoding.rowMajor),
        ResultEncoding.rowMajor,
      );
    });

    test('should_clamp_columnar_to_row_major', () {
      expect(
        forQueryResultWire(ResultEncoding.columnar),
        ResultEncoding.rowMajor,
      );
    });

    test('should_clamp_columnar_compressed_to_row_major', () {
      expect(
        forQueryResultWire(ResultEncoding.columnarCompressed),
        ResultEncoding.rowMajor,
      );
    });
  });

  group('QueryResult buffered encoding routing', () {
    test(
      'should_keep_row_shaped_buffered_apis_on_row_major_'
      'even_when_default_is_columnar',
      () {
        // Contract: executeQueryParamValues / executeQueryParamBuffer always
        // request row-major wire regardless of repository
        // defaultResultEncoding. Columnar consumers must use
        // executeQueryColumnar*.
        final state = OdbcRepositoryState(
          defaultResultEncoding: ResultEncoding.columnar,
        );
        expect(state.defaultResultEncoding.isColumnar, isTrue);
        final wire = forQueryResultWire(state.defaultResultEncoding);
        expect(wire, ResultEncoding.rowMajor);
        expect(wire.isColumnar, isFalse);
      },
    );

    test(
      'should_ignore_explicit_columnar_request_on_query_result_path',
      () {
        expect(
          forQueryResultWire(ResultEncoding.columnar),
          ResultEncoding.rowMajor,
        );
      },
    );
  });
}
