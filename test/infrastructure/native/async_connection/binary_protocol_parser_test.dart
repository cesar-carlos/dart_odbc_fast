import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('BinaryProtocolParser', () {
    test(
      'should throw FormatException instead of RangeError when '
      'buffer is truncated',
      () {
        final header = Uint8List(BinaryProtocolParser.headerSize);
        ByteData.sublistView(header)
          ..setUint32(0, BinaryProtocolParser.magic, Endian.little)
          ..setUint16(4, 1, Endian.little)
          ..setUint16(6, 0, Endian.little)
          ..setUint32(8, 0, Endian.little)
          ..setUint32(12, 1000, Endian.little);

        expect(
          () => BinaryProtocolParser.parse(header),
          throwsA(isA<FormatException>()),
        );
        try {
          BinaryProtocolParser.parse(header);
          fail('Should have thrown FormatException');
        } on FormatException catch (e) {
          expect(e.message, contains('Buffer too small for payload'));
        }
      },
    );
  });
}
