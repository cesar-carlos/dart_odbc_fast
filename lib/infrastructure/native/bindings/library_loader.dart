import 'dart:ffi';
import 'dart:io';

import 'package:meta/meta.dart';

/// Gets the platform-specific ODBC engine library name.
///
/// Returns 'odbc_engine.dll' on Windows or 'libodbc_engine.so' on Linux.
String _libraryName() {
  if (Platform.isWindows) {
    return 'odbc_engine.dll';
  }
  if (Platform.isLinux) {
    return 'libodbc_engine.so';
  }
  throw UnsupportedError('Platform not supported: ${Platform.operatingSystem}');
}

/// Finds package root by walking up until a directory contains pubspec.yaml.
String? _findPackageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return null;
    }
    dir = parent;
  }
}

String? _existingPathUnderRoot(String root, String name, String sep) {
  final workspace = '$root${sep}native${sep}target${sep}release$sep$name';
  if (File(workspace).existsSync()) {
    return File(workspace).absolute.path;
  }
  final local =
      '$root${sep}native${sep}odbc_engine${sep}target${sep}release$sep$name';
  if (File(local).existsSync()) {
    return File(local).absolute.path;
  }
  return null;
}

DynamicLibrary? _tryLoadFromRoot(String root, String name, String sep) {
  final path = _existingPathUnderRoot(root, name, sep);
  if (path == null) {
    return null;
  }
  return DynamicLibrary.open(path);
}

/// Returns the loaded [DynamicLibrary] instance.
///
/// Resolution order (aligned with `hook/build.dart` / `doc/BUILD.md`):
/// 1. Development local — `native/target/release/` (workspace) or
///    `native/odbc_engine/target/release/` (crate-local), from cwd then package
///    root
/// 2. Native Assets — `package:odbc_fast/<lib>` (hook cache / download)
/// 3. System library paths — PATH / LD_LIBRARY_PATH
DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();
  final localPath = findFirstExistingOdbcEnginePath(
    cwd: Directory.current.path,
    packageRoot: _findPackageRoot(),
  );
  if (localPath != null) {
    return DynamicLibrary.open(localPath);
  }

  // Native Assets (production) - package:odbc_fast/
  try {
    return DynamicLibrary.open('package:odbc_fast/$name');
  } on Object catch (_) {
    // Native Assets not available, continue to next option
  }

  // System - PATH/LD_LIBRARY_PATH
  try {
    return DynamicLibrary.open(name);
  } catch (e) {
    throw StateError(
      'ODBC engine library not found.\n\n'
      'Options:\n'
      '1. For development: Build Rust library first\n'
      '   cd native && cargo build --release\n\n'
      '2. Automatic download: Run "dart pub get" again\n'
      '   (Binary will be downloaded from GitHub Releases)\n\n'
      '3. Manual download: Get binary from GitHub Releases\n'
      '   https://github.com/cesar-carlos/dart_odbc_fast/releases\n\n'
      'Error: $e',
    );
  }
}

/// Loads the ODBC engine library from a specific file path.
///
/// The [path] must be a valid absolute or relative path to the library file.
///
/// Returns the loaded [DynamicLibrary] instance.
DynamicLibrary loadOdbcLibraryFromPath(String path) {
  return DynamicLibrary.open(path);
}

/// Attempts to load the ODBC engine library from application assets.
///
/// Native Assets are handled by `hook/build.dart` and resolved through
/// [loadOdbcLibrary]. Kept for API compatibility.
///
/// Returns the loaded [DynamicLibrary] if found, null otherwise.
DynamicLibrary? loadOdbcLibraryFromAssets() {
  return null;
}

/// Platform-specific ODBC engine file name (`odbc_engine.dll` / `libodbc_engine.so`).
@visibleForTesting
String odbcEngineLibraryFileName() => _libraryName();

/// Walks upward from [Directory.current] until `pubspec.yaml` is found.
@visibleForTesting
String? findOdbcPackageRoot() => _findPackageRoot();

/// Workspace then crate-local release paths under [root].
@visibleForTesting
List<String> odbcEngineLocalReleasePaths(String root) {
  final name = _libraryName();
  final sep = Platform.pathSeparator;
  return [
    '$root${sep}native${sep}target${sep}release$sep$name',
    '$root${sep}native${sep}odbc_engine${sep}target${sep}release$sep$name',
  ];
}

/// First existing local release path: [cwd] before [packageRoot], workspace
/// before crate-local. Does not consult Native Assets or PATH.
@visibleForTesting
String? findFirstExistingOdbcEnginePath({
  required String cwd,
  String? packageRoot,
}) {
  final name = _libraryName();
  final sep = Platform.pathSeparator;
  final fromCwd = _existingPathUnderRoot(cwd, name, sep);
  if (fromCwd != null) {
    return fromCwd;
  }
  if (packageRoot != null && packageRoot != cwd) {
    return _existingPathUnderRoot(packageRoot, name, sep);
  }
  return null;
}

/// Tries dev release paths under [root] without falling back to system PATH.
@visibleForTesting
DynamicLibrary? tryLoadOdbcEngineFromProjectRoot(String root) {
  return _tryLoadFromRoot(root, _libraryName(), Platform.pathSeparator);
}
