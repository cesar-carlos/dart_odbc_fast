import 'package:odbc_fast/infrastructure/native/columnar_decompress_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('isColumnarNativeDecompressAvailable is bool', () {
    resetColumnarDecompressForTest();
    expect(isColumnarNativeDecompressAvailable, isA<bool>());
  });
}
