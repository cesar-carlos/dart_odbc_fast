import 'dart:typed_data';

import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

void main() {
  group('validateDirectedOutInOut', () {
    test('input passes for binary', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.input,
          const ParamValueBinary([1]),
        ),
        returnsNormally,
      );
    });

    test('output binary is rejected with DIRECTED_PARAM prefix', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.output,
          const ParamValueBinary([1]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString().contains('DIRECTED_PARAM|'),
            'message',
            true,
          ),
        ),
      );
    });

    test('inOut null is rejected', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.inOut,
          const ParamValueNull(),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString().contains('inout_null'),
            'slug',
            true,
          ),
        ),
      );
    });

    test('inOut empty decimal is rejected', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.inOut,
          const ParamValueDecimal(''),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e
                .toString()
                .contains('decimal_inout_out_requires_non_empty'),
            'slug',
            true,
          ),
        ),
      );
    });
  });

  group('serializeDirectedParams enforces out validation', () {
    test('binary out throws', () {
      expect(
        () => serializeDirectedParams([
          DirectedParam(
            value: Uint8List.fromList([1]),
            direction: ParamDirection.output,
          ),
        ]),
        throwsArgumentError,
      );
    });
  });
}
