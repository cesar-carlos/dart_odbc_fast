import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:test/test.dart';

void main() {
  group('Native Assets', () {
    test(
      'should load library via Native Assets',
      () {
        expect(loadOdbcLibrary, returnsNormally);
      },
      skip: 'Requires built library or Native Assets setup',
    );

    test(
      'should load library from custom path',
      () {
        final lib = loadOdbcLibraryFromPath('custom/path/to/lib');
        expect(lib, isNotNull);
      },
      skip: 'Requires custom library path',
    );
  });
}
