import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:test/test.dart';

import 'helpers/load_env.dart';

void main() {
  loadTestEnv();

  group('Native Assets', () {
    test(
      'should load library via Native Assets',
      () {
        expect(loadOdbcLibrary, returnsNormally);
      },
      skip: runSkippedTests
          ? null
          : 'Requires built library or Native Assets setup',
    );

    test(
      'should load library from custom path',
      () {
        final path = getTestEnv('ODBC_CUSTOM_LIB_PATH');
        expect(path, isNotNull);
        final lib = loadOdbcLibraryFromPath(path!);
        expect(lib, isNotNull);
      },
      skip: getTestEnv('ODBC_CUSTOM_LIB_PATH') == null ||
              getTestEnv('ODBC_CUSTOM_LIB_PATH')!.isEmpty
          ? 'Set ODBC_CUSTOM_LIB_PATH to an existing native library file'
          : null,
    );
  });
}
