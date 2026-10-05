import 'dart:io';

/// User defines survive the SDK's hermetic hook environment.
Uri? configuredNativeLibraryUri(Uri? directory, String libraryName) {
  if (directory == null) return null;
  final base =
      directory.toString().endsWith('/') ? directory : Uri.parse('$directory/');
  final file = File.fromUri(base.resolve(libraryName));
  if (!file.existsSync()) {
    throw StateError('Configured native artifact is missing: ${file.path}');
  }
  return file.absolute.uri;
}

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
