import 'dart:io';

/// Selects an explicitly built engine instead of a version-only download cache.
Uri? explicitNativeLibraryUri([Map<String, String>? environment]) {
  final path =
      (environment ?? Platform.environment)['ODBC_FAST_NATIVE_LIBRARY'];
  if (path == null || path.trim().isEmpty) return null;
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      'ODBC_FAST_NATIVE_LIBRARY does not point to an existing file',
    );
  }
  return file.absolute.uri;
}
