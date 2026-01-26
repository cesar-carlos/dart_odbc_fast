import 'dart:ffi';
import 'dart:io';

/// Gets the platform-specific ODBC engine library name.
///
/// Returns 'odbc_engine.dll' on Windows, 'libodbc_engine.so' on Linux,
/// or 'libodbc_engine.dylib' on macOS.
String _libraryName() {
  if (Platform.isWindows) {
    return 'odbc_engine.dll';
  }
  if (Platform.isLinux) {
    return 'libodbc_engine.so';
  }
  if (Platform.isMacOS) {
    return 'libodbc_engine.dylib';
  }
  throw UnsupportedError('Platform not supported: ${Platform.operatingSystem}');
}

/// Gets the relative path to the ODBC engine library.
///
/// Returns a path relative to the project root in the format:
/// 'native/target/release/{library_name}'.
String _relativeLibraryPath() {
  const sep = '/';
  return 'native${sep}target${sep}release$sep${_libraryName()}';
}

/// Loads the ODBC engine library from the default location.
///
/// First tries to load from the relative path in the project directory,
/// then falls back to loading by name from system library paths.
///
/// Returns the loaded [DynamicLibrary] instance.
DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();
  final relative = _relativeLibraryPath();
  final cwd = Directory.current.path;
  final path = '$cwd${Platform.pathSeparator}'
      '${relative.replaceAll("/", Platform.pathSeparator)}';
  final file = File(path);
  if (file.existsSync()) {
    return DynamicLibrary.open(path);
  }
  return DynamicLibrary.open(name);
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
/// Currently not implemented and always returns null.
///
/// Returns the loaded [DynamicLibrary] if found, null otherwise.
DynamicLibrary? loadOdbcLibraryFromAssets() {
  try {
    return null;
  } on Exception catch (_) {
    return null;
  }
}
