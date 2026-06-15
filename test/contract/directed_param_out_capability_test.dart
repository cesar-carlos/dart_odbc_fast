/// Contract: OUT/INOUT binary directed params are explicitly unsupported.
library;

import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:test/test.dart';

void main() {
  group('directed param OUT/INOUT binary capability contract', () {
    test('barrel exports validateDirectedOutInOut for consumers', () {
      expect(validateDirectedOutInOut, isNotNull);
      expect(kDirectedParamErrorPrefix, equals('DIRECTED_PARAM|'));
    });

    test('should_reject_output_binary_with_stable_slug', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.output,
          const ParamValueBinary([1, 2]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('DIRECTED_PARAM|binary_out_inout_not_implemented'),
          ),
        ),
      );
    });

    test('should_reject_inOut_binary_with_stable_slug', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.inOut,
          const ParamValueBinary([1]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('DIRECTED_PARAM|binary_out_inout_not_implemented'),
          ),
        ),
      );
    });

    test('serializeDirectedParams rejects binary output before wire encode',
        () {
      expect(
        () => serializeDirectedParams([
          DirectedParam(
            value: Uint8List.fromList([9]),
            direction: ParamDirection.output,
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('input binary remains allowed', () {
      expect(
        () => validateDirectedOutInOut(
          ParamDirection.input,
          const ParamValueBinary([1]),
        ),
        returnsNormally,
      );
    });
  });
}
