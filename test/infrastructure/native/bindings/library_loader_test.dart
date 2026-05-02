import 'package:odbc_fast/infrastructure/native/bindings/library_loader.dart';
import 'package:test/test.dart';

void main() {
  group('library_loader', () {
    test('loadOdbcLibraryFromAssets returns null', () {
      expect(loadOdbcLibraryFromAssets(), isNull);
    });

    test('loadOdbcLibraryFromPath throws when path does not exist', () {
      expect(
        () => loadOdbcLibraryFromPath(
          'nonexistent_odbc_engine_library_for_test.dll',
        ),
        throwsA(anything),
      );
    });
  });
}
