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

/// When true, a local release artifact wins over cache even if older.
bool preferLocalOdbcEngineBuild([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  return env['ODBC_FAST_PREFER_LOCAL_BUILD'] == 'true';
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

String? _versionFromPubspec(String packageRoot) {
  final sep = Platform.pathSeparator;
  final pubspec = File('$packageRoot${sep}pubspec.yaml');
  if (!pubspec.existsSync()) {
    return null;
  }
  try {
    for (final line in pubspec.readAsLinesSync()) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#')) {
        continue;
      }
      if (trimmed.startsWith('version:')) {
        final raw = trimmed.substring('version:'.length).trim();
        final version = raw.split(RegExp(r'\s+#')).first.trim();
        return version.isEmpty ? null : version;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// Hook cache path for the current host (x64 Windows/Linux only).
@visibleForTesting
String? odbcEngineCachedLibraryPath({
  required String libName,
  String? packageRoot,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null) {
    return null;
  }

  final version = packageRoot == null ? null : _versionFromPubspec(packageRoot);
  final cacheBase = version == null || version.isEmpty
      ? '$home${Platform.pathSeparator}.cache${Platform.pathSeparator}'
          'odbc_fast'
      : '$home${Platform.pathSeparator}.cache${Platform.pathSeparator}'
          'odbc_fast${Platform.pathSeparator}$version';

  final platformDir = Platform.isWindows
      ? 'windows_x64'
      : Platform.isLinux
          ? 'linux_x64'
          : null;
  if (platformDir == null) {
    return null;
  }

  final cached = File(
    '$cacheBase${Platform.pathSeparator}$platformDir'
    '${Platform.pathSeparator}$libName',
  );
  if (!cached.existsSync()) {
    return null;
  }
  return cached.absolute.path;
}

/// Picks between local and cached paths using the same policy as
/// `hook/native_library_resolver.dart` `chooseLocalOrCached`.
@visibleForTesting
String? chooseLocalOrCachedLibraryPath({
  required String? localPath,
  required String? cachedPath,
  bool preferLocal = false,
  DateTime Function(String path)? modifiedAt,
}) {
  DateTime mtime(String path) {
    if (modifiedAt != null) {
      return modifiedAt(path);
    }
    return File(path).lastModifiedSync();
  }

  if (preferLocal && localPath != null) {
    return localPath;
  }

  if (localPath != null && cachedPath != null) {
    final localTime = mtime(localPath);
    final cachedTime = mtime(cachedPath);
    if (!localTime.isBefore(cachedTime)) {
      return localPath;
    }
    return cachedPath;
  }

  return cachedPath ?? localPath;
}

/// Resolves the preferred on-disk library path before Native Assets / PATH.
String? resolvePreferredOdbcEngineFilePath({
  required String cwd,
  String? packageRoot,
  Map<String, String>? environment,
  DateTime Function(String path)? modifiedAt,
}) {
  final name = _libraryName();
  final localPath = findFirstExistingOdbcEnginePath(
    cwd: cwd,
    packageRoot: packageRoot,
  );
  final cachedPath = odbcEngineCachedLibraryPath(
    libName: name,
    packageRoot: packageRoot ?? (localPath == null ? null : cwd),
    environment: environment,
  );
  return chooseLocalOrCachedLibraryPath(
    localPath: localPath,
    cachedPath: cachedPath,
    preferLocal: preferLocalOdbcEngineBuild(environment),
    modifiedAt: modifiedAt,
  );
}

/// Returns the loaded [DynamicLibrary] instance.
///
/// Resolution order (aligned with `hook/build.dart` / `doc/BUILD.md`):
/// 1. Preferred on-disk file — local release vs `~/.cache/odbc_fast/...`
///    using `ODBC_FAST_PREFER_LOCAL_BUILD` and mtime (same policy as the hook)
/// 2. Native Assets — `package:odbc_fast/<lib>` (hook-registered asset)
/// 3. System library paths — PATH / LD_LIBRARY_PATH
DynamicLibrary loadOdbcLibrary() {
  final name = _libraryName();
  final packageRoot = _findPackageRoot();
  final preferred = resolvePreferredOdbcEngineFilePath(
    cwd: Directory.current.path,
    packageRoot: packageRoot,
  );
  if (preferred != null) {
    return DynamicLibrary.open(preferred);
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
