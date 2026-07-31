import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:odbc_fast/infrastructure/native/protocol/odbc_type.dart';
import 'package:test/test.dart';

void main() {
  group('decodeProtocolCell binary scalar dual-support', () {
    test('should_decode_le_float64_when_payload_is_8_bytes', () {
      // Non-ASCII-float LE payload (quiet NaN bit pattern fails ASCII parse).
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setFloat64(0, 42.5, Endian.little);
      final value = decodeProtocolCell(
        bytes,
        OdbcType.doublePrecision.discriminant,
      );
      expect(value, closeTo(42.5, 1e-12));
    });

    test('should_prefer_ascii_infinity_over_le_reinterpretation', () {
      final value = decodeProtocolCell(
        Uint8List.fromList('Infinity'.codeUnits),
        OdbcType.float.discriminant,
      );
      expect(value, double.infinity);
    });

    test('should_decode_ascii_float_when_payload_is_text', () {
      final value = decodeProtocolCell(
        Uint8List.fromList('3.14'.codeUnits),
        OdbcType.float.discriminant,
      );
      expect(value, closeTo(3.14, 1e-12));
    });

    test('should_decode_single_byte_bool', () {
      expect(
        decodeProtocolCell(
          Uint8List.fromList([1]),
          OdbcType.boolean.discriminant,
        ),
        isTrue,
      );
      expect(
        decodeProtocolCell(
          Uint8List.fromList([0]),
          OdbcType.boolean.discriminant,
        ),
        isFalse,
      );
    });

    test('should_decode_ascii_bool_text', () {
      expect(
        decodeProtocolCell(
          Uint8List.fromList('true'.codeUnits),
          OdbcType.boolean.discriminant,
        ),
        isTrue,
      );
    });
  });
}
