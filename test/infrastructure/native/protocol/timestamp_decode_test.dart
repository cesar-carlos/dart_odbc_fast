import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol_cell_decode.dart';
import 'package:test/test.dart';

void main() {
  test('should_preserve_timestamp_precision_normalization_and_zone', () {
    for (final input in [
      '0000-01-01 00:00:00.000000',
      '9999-12-31 23:59:59.999999',
      '2024-02-29 23:59:59.000001',
      '2023-02-29 24:00:00.019001',
      '2024-11-03 01:30:00.123456',
      '2024-03-10 02:30:00.000999',
      '2024-11-03T01:30:00.000123Z',
      '2024-05-06 12:13:14+02:30',
      ' 2024-05-06 12:13:14.1234567 ',
    ]) {
      final frame = Uint8List.fromList([0, ...ascii.encode(input), 0]);
      final view = Uint8List.sublistView(frame, 1, frame.length - 1);
      final value = decodeProtocolCell(view, 6)! as DateTime;
      final expected = DateTime.parse(input.trim());
      expect(
        value.microsecondsSinceEpoch,
        expected.microsecondsSinceEpoch,
        reason: input,
      );
      expect(value.isUtc, expected.isUtc, reason: input);
    }
  });

  test('should_preserve_unparseable_timestamp_cells_as_text', () {
    const valid = '2024-05-06 12:13:14.123456';
    for (var i = 0; i < valid.length; i++) {
      final input = valid.replaceRange(i, i + 1, 'x');
      expect(
        decodeProtocolCell(Uint8List.fromList(ascii.encode(input)), 6),
        input,
      );
    }
  });
}
