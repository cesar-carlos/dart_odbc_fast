import 'dart:io';

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

    test('odbcEngineLibraryFileName matches platform', () {
      if (Platform.isWindows) {
        expect(odbcEngineLibraryFileName(), 'odbc_engine.dll');
      } else if (Platform.isLinux) {
        expect(odbcEngineLibraryFileName(), 'libodbc_engine.so');
      } else {
        expect(
          odbcEngineLibraryFileName,
          throwsA(isA<UnsupportedError>()),
        );
      }
    });

    test('findOdbcPackageRoot locates pubspec from test runner cwd', () {
      final root = findOdbcPackageRoot();
      expect(root, isNotNull);
      final sep = Platform.pathSeparator;
      expect(
        File('$root${sep}pubspec.yaml').existsSync(),
        isTrue,
        reason: 'package root should contain pubspec.yaml',
      );
    });

    test('tryLoadOdbcEngineFromProjectRoot returns null when no release build',
        () {
      final temp = Directory.systemTemp.createTempSync('odbc_loader_test_');
      addTearDown(temp.deleteSync);
      expect(tryLoadOdbcEngineFromProjectRoot(temp.path), isNull);
    });

    test(
      'tryLoadOdbcEngineFromProjectRoot opens workspace release when present',
      () {
        final root = findOdbcPackageRoot();
        expect(root, isNotNull);
        final name = odbcEngineLibraryFileName();
        final sep = Platform.pathSeparator;
        final releasePath =
            '$root${sep}native${sep}target${sep}release$sep$name';
        if (!File(releasePath).existsSync()) {
          markTestSkipped('No dev build at $releasePath');
        }
        final lib = tryLoadOdbcEngineFromProjectRoot(root!);
        expect(lib, isNotNull);
      },
    );
  });
}
