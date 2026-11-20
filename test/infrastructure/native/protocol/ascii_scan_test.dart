import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/protocol_ascii_parse.dart';
import 'package:test/test.dart';

void main() {
  test('should_detect_each_high_bit_only_within_the_byte_view', () {
    for (final length in [0, 1, 63, 64, 65, 511, 512, 513]) {
      for (var offset = 0; offset < 4; offset++) {
        final bytes = Uint8List(length + 8)..fillRange(0, length + 8, 255);
        final view = Uint8List.sublistView(bytes, offset, offset + length)
          ..fillRange(0, length, 127);
        expect(isAsciiBytes(view), isTrue);
        for (var i = 0; i < length; i++) {
          view[i] = 128;
          expect(isAsciiBytes(view), isFalse);
          view[i] = 127;
        }
      }
    }
  });
}
