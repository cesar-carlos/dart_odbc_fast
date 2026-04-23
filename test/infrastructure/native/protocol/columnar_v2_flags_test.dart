import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/columnar_v2_flags.dart';
import 'package:test/test.dart';

void main() {
  test('magic constant matches Rust COLUMNAR_V2_MAGIC', () {
    final buf = Uint8List(4);
    ByteData.sublistView(buf).setUint32(0, columnarV2Magic, Endian.little);
    expect(String.fromCharCodes(buf), equals('ODBC'));
  });

  test('isLikelyColumnarV2Header', () {
    final ok = Uint8List(8);
    ByteData.sublistView(ok).setUint32(0, columnarV2Magic, Endian.little);
    expect(isLikelyColumnarV2Header(ok), isTrue);
    expect(isLikelyColumnarV2Header(Uint8List(2)), isFalse);
  });
}
