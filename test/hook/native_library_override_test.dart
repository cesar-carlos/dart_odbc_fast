import 'dart:io';

import 'package:odbc_fast/src/native_assets/native_library_override.dart';
import 'package:test/test.dart';

void main() {
  test('missing explicit artifact fails instead of using a cached engine', () {
    expect(
      () => explicitNativeLibraryUri({
        'ODBC_FAST_NATIVE_LIBRARY': 'missing-engine-qualification.dll',
      }),
      throwsStateError,
    );
  });
  test('explicit artifact resolves to its absolute URI', () {
    final directory = Directory.systemTemp.createTempSync('odbc-explicit-');
    try {
      final file = File('${directory.path}/engine.dll')..writeAsBytesSync([1]);
      expect(
        explicitNativeLibraryUri({'ODBC_FAST_NATIVE_LIBRARY': file.path}),
        file.absolute.uri,
      );
      expect(explicitNativeLibraryUri({}), isNull);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
