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
        final lib = loadOdbcLibraryFromPath('custom/path/to/lib');
        expect(lib, isNotNull);
      },
      skip: runSkippedTests ? null : 'Requires custom library path',
    );
  });
}
