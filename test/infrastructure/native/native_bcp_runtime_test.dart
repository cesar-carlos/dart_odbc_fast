import 'package:odbc_fast/infrastructure/native/native_bcp_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('isUnstableNativeBcpEnabled', () {
    test('should_be_false_when_env_unset', () {
      expect(isUnstableNativeBcpEnabled, isFalse);
    });
  });
}
