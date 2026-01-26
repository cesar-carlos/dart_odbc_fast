import 'dart:ffi';
import 'dart:io';

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

String _relativeLibraryPath() {
  const sep = '/';
  return 'native${sep}target${sep}release${sep}${_libraryName()}';
}

DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();
  final relative = _relativeLibraryPath();
  final cwd = Directory.current.path;
  final path =
      '$cwd${Platform.pathSeparator}${relative.replaceAll("/", Platform.pathSeparator)}';
  final file = File(path);
  if (file.existsSync()) {
    return DynamicLibrary.open(path);
  }
  return DynamicLibrary.open(name);
}

DynamicLibrary loadOdbcLibraryFromPath(String path) {
  return DynamicLibrary.open(path);
}

DynamicLibrary? loadOdbcLibraryFromAssets() {
  try {
    return null;
  } catch (e) {
    return null;
  }
}
