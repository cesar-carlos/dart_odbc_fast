import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:test/test.dart';

void main() {
  final values = <ParamValue>[
    const ParamValueNull(),
    const ParamValueString('açúcar 😀'),
    const ParamValueInt32(-2147483648),
    const ParamValueInt64(9223372036854775807),
    const ParamValueDecimal('-123.450'),
    ParamValueBinary(Uint8List.fromList([0, 127, 255])),
    const ParamValueRefCursorOut(),
  ];

  group('parameter decoding views', () {
    test('should_return_empty_list_when_view_is_empty', () {
      final empty = Uint8List.sublistView(Uint8List(16), 8, 8);
      expect(deserializeParamValues(empty), isEmpty);
      expect(() => deserializeParamValue(empty), throwsFormatException);
    });

    test('should_reject_each_truncated_scalar_when_decoding_a_view', () {
      for (final value in values) {
        final wire = serializeParams([value]);
        final backing = Uint8List(wire.length + 7)
          ..setRange(7, 7 + wire.length, wire);
        for (var length = 0; length < wire.length; length++) {
          final view = Uint8List.sublistView(backing, 7, 7 + length);
          expect(
            () => deserializeParamValue(view),
            throwsFormatException,
            reason: '${value.runtimeType}, prefix length $length',
          );
        }
      }
    });

    for (var prefix = 1; prefix <= 8; prefix++) {
      test('should_decode_all_tags_when_view_has_prefix_$prefix', () {
        final wire = serializeParams(values);
        final backing = Uint8List(prefix + wire.length + 16)
          ..fillRange(0, prefix, 255)
          ..setRange(prefix, prefix + wire.length, wire);
        final view = Uint8List.sublistView(
          backing,
          prefix,
          prefix + wire.length,
        );

        expect(serializeParams(deserializeParamValues(view)), wire);
        var offset = 0;
        for (final expected in values) {
          final decoded = deserializeParamValue(view, offset: offset);
          final expectedWire = serializeParams([expected]);
          expect(serializeParams([decoded.value]), expectedWire);
          expect(decoded.consumed, expectedWire.length);
          offset += decoded.consumed;
        }
        expect(offset, view.length);
      });
    }

    test('should_reject_truncation_when_backing_contains_remaining_bytes', () {
      final wire = serializeParams([const ParamValueInt64(42)]);
      final backing = Uint8List(wire.length + 3)
        ..setRange(3, 3 + wire.length, wire);
      final truncated = Uint8List.sublistView(backing, 3, backing.length - 1);

      expect(() => deserializeParamValue(truncated), throwsFormatException);
      expect(() => deserializeParamValues(truncated), throwsFormatException);
    });

    test('should_preserve_binary_view_ownership_when_decoding', () {
      final wire = serializeParams([
        ParamValueBinary(Uint8List.fromList([1, 2, 3])),
      ]);
      final decoded = deserializeParamValue(wire).value as ParamValueBinary;
      wire[5] = 99;

      expect(decoded.value, [99, 2, 3]);
      expect((decoded.value as Uint8List).buffer, wire.buffer);
    });
  });
}
