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

    test('odbcEngineLocalReleasePaths_lists_workspace_before_crate_local', () {
      const root = r'D:\proj';
      final paths = odbcEngineLocalReleasePaths(root);
      final name = odbcEngineLibraryFileName();
      final sep = Platform.pathSeparator;
      final crateLocal =
          '$root${sep}native${sep}odbc_engine${sep}target${sep}release'
          '$sep$name';
      expect(
        paths,
        [
          '$root${sep}native${sep}target${sep}release$sep$name',
          crateLocal,
        ],
      );
    });

    test(
      'findFirstExistingOdbcEnginePath_prefers_cwd_over_package_root',
      () {
        final temp = Directory.systemTemp.createTempSync('odbc_loader_prio_');
        addTearDown(() => temp.deleteSync(recursive: true));

        final cwdRoot = Directory('${temp.path}/cwd')..createSync();
        final pkgRoot = Directory('${temp.path}/pkg')..createSync();
        final name = odbcEngineLibraryFileName();

        final cwdLib = File(
          '${cwdRoot.path}/native/target/release/$name',
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync(const [0]);
        final pkgLib = File(
          '${pkgRoot.path}/native/target/release/$name',
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync(const [1]);

        final found = findFirstExistingOdbcEnginePath(
          cwd: cwdRoot.path,
          packageRoot: pkgRoot.path,
        );
        expect(found, isNotNull);
        expect(
          FileSystemEntity.identicalSync(found!, cwdLib.path),
          isTrue,
          reason: 'cwd local release must win over package-root release',
        );
        expect(
          FileSystemEntity.identicalSync(found, pkgLib.path),
          isFalse,
        );
      },
    );

    test(
      'findFirstExistingOdbcEnginePath_uses_package_root_when_cwd_empty',
      () {
        final temp = Directory.systemTemp.createTempSync('odbc_loader_pkg_');
        addTearDown(() => temp.deleteSync(recursive: true));

        final cwdRoot = Directory('${temp.path}/cwd')..createSync();
        final pkgRoot = Directory('${temp.path}/pkg')..createSync();
        final name = odbcEngineLibraryFileName();

        final pkgLib = File(
          '${pkgRoot.path}/native/target/release/$name',
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync(const [1]);

        final found = findFirstExistingOdbcEnginePath(
          cwd: cwdRoot.path,
          packageRoot: pkgRoot.path,
        );
        expect(found, isNotNull);
        expect(
          FileSystemEntity.identicalSync(found!, pkgLib.path),
          isTrue,
        );
      },
    );

    test(
      'findFirstExistingOdbcEnginePath_prefers_workspace_over_crate_local',
      () {
        final temp = Directory.systemTemp.createTempSync('odbc_loader_ws_');
        addTearDown(() => temp.deleteSync(recursive: true));
        final name = odbcEngineLibraryFileName();

        final workspace = File(
          '${temp.path}/native/target/release/$name',
        )
          ..createSync(recursive: true)
          ..writeAsBytesSync(const [0]);
        File('${temp.path}/native/odbc_engine/target/release/$name')
          ..createSync(recursive: true)
          ..writeAsBytesSync(const [1]);

        final found = findFirstExistingOdbcEnginePath(
          cwd: temp.path,
          packageRoot: temp.path,
        );
        expect(found, isNotNull);
        expect(
          FileSystemEntity.identicalSync(found!, workspace.path),
          isTrue,
        );
      },
    );

    test(
      'findFirstExistingOdbcEnginePath_returns_null_when_no_local_build',
      () {
        final temp = Directory.systemTemp.createTempSync('odbc_loader_none_');
        addTearDown(() => temp.deleteSync(recursive: true));
        expect(
          findFirstExistingOdbcEnginePath(
            cwd: temp.path,
            packageRoot: temp.path,
          ),
          isNull,
        );
      },
    );

    test(
      'loadOdbcLibrary_uses_local_path_before_falling_through',
      () {
        final root = findOdbcPackageRoot();
        expect(root, isNotNull);
        final local = findFirstExistingOdbcEnginePath(
          cwd: Directory.current.path,
          packageRoot: root,
        );
        if (local == null) {
          markTestSkipped('No local release build available');
        }
        // Contract: when a local release exists, loadOdbcLibrary must succeed
        // without depending solely on package: Native Assets / PATH.
        expect(loadOdbcLibrary, returnsNormally);
        expect(
          File(local!).existsSync(),
          isTrue,
          reason: 'local candidate used by loadOdbcLibrary step 1',
        );
      },
    );
  });
}
