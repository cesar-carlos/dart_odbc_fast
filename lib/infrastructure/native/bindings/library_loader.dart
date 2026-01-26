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
///
/// Returns the loaded [DynamicLibrary] instance.
DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();

  // 1. Native Assets (production) - baixado automaticamente da GitHub Release
  // O hook/build.dart baixa e registra o asset, que é carregado aqui
  try {
    return DynamicLibrary.open('package:odbc_fast/$name');
  } on Object catch (_) {
    // Native Assets não disponível, continua para próxima opção
  }

  // 2. Desenvolvimento local - native/target/release/ (workspace target)
  final cwd = Directory.current.path;
  final devPathWorkspace = '$cwd${Platform.pathSeparator}native'
      '${Platform.pathSeparator}target${Platform.pathSeparator}release'
      '${Platform.pathSeparator}$name';

  if (File(devPathWorkspace).existsSync()) {
    return DynamicLibrary.open(devPathWorkspace);
  }

  // 2b. Fallback: native/odbc_engine/target/release/ (local target)
  final devPathLocal = '$cwd${Platform.pathSeparator}native'
      '${Platform.pathSeparator}odbc_engine${Platform.pathSeparator}target'
      '${Platform.pathSeparator}release${Platform.pathSeparator}$name';

  if (File(devPathLocal).existsSync()) {
    return DynamicLibrary.open(devPathLocal);
  }

  // 3. Sistema - PATH/LD_LIBRARY_PATH
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
