import 'dart:ffi';
import 'dart:io';

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

/// Loads the ODBC engine library from the default location.
///
/// Uses a priority-based loading strategy:
/// 1. Native Assets (automatic download from GitHub Releases)
/// 2. Development local - native/target/release/ (workspace) or native/odbc_engine/target/release/ (local)
/// 3. System library paths - PATH/LD_LIBRARY_PATH
/// 4. Custom path - allows loading from custom path (for debugging)
///
/// Finds package root by walking up until a directory contains pubspec.yaml.
String? _findPackageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

DynamicLibrary? _tryLoadFromRoot(String root, String name, String sep) {
  final workspace = '$root${sep}native${sep}target${sep}release$sep$name';
  final fWorkspace = File(workspace);
  if (fWorkspace.existsSync()) {
    return DynamicLibrary.open(fWorkspace.absolute.path);
  }
  final local =
      '$root${sep}native${sep}odbc_engine${sep}target${sep}release$sep$name';
  final fLocal = File(local);
  if (fLocal.existsSync()) {
    return DynamicLibrary.open(fLocal.absolute.path);
  }
  return null;
}

/// Returns the loaded [DynamicLibrary] instance.
DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();
  final cwd = Directory.current.path;
  final sep = Platform.pathSeparator;

  // 1. CWD-relative (e.g. when running from project root)
  final fromCwd = _tryLoadFromRoot(cwd, name, sep);
  if (fromCwd != null) return fromCwd;

  // 2. Package root-relative (e.g. when dart test runs from test/subdir)
  final root = _findPackageRoot();
  if (root != null) {
    final fromRoot = _tryLoadFromRoot(root, name, sep);
    if (fromRoot != null) return fromRoot;
  }

  // 3. Native Assets (production) - package:odbc_fast/
  try {
    return DynamicLibrary.open('package:odbc_fast/$name');
  } on Object catch (_) {
    // Native Assets not available, continue to next option
  }

  // 4. Sistema - PATH/LD_LIBRARY_PATH
  try {
    return DynamicLibrary.open(name);
  } catch (e) {
    throw StateError(
      'ODBC engine library not found.\n\n'
      'Options:\n'
      '1. Automatic download: Run "dart pub get" again\n'
      '   (Binary will be downloaded from GitHub Releases)\n\n'
      '2. For development: Build Rust library first\n'
      '   cd native/odbc_engine && cargo build --release\n\n'
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
/// This is now handled automatically by Native Assets via the build hook.
/// The hook downloads binaries from GitHub Releases to ~/.cache/odbc_fast/
///
/// Returns the loaded [DynamicLibrary] if found, null otherwise.
DynamicLibrary? loadOdbcLibraryFromAssets() {
  // Native Assets handles this automatically via hook/build.dart
  // This method is kept for API compatibility but is no longer used
  return null;
}
