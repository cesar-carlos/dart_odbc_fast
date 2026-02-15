import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final targetArchitecture = input.config.code.targetArchitecture;

    // Define native library name by platform
    final libName = _getLibraryName(targetOS);

    // Path to the compiled library.
    final libPath = await _getLibraryPath(
      targetOS,
      targetArchitecture,
      input.packageRoot,
      packageName,
    );

    // If library is not found, do not add the asset
    // (allows tests to continue without native library)
    if (libPath == null) {
      return;
    }

    // Register the native asset.
    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: libName,
        linkMode: DynamicLoadingBundled(),
        file: libPath,
      ),
    );
  });
}

/// Checks whether external download should be skipped (CI/pub.dev environments).
bool _shouldSkipDownload() {
  // Skip download when PUB_ENVIRONMENT is set (pub.dev context)
  final pubEnv = Platform.environment['PUB_ENVIRONMENT'];
  if (pubEnv != null && pubEnv.contains('pub.dev')) {
    return true;
  }

  // Skip download when CI is set
  final ci = Platform.environment['CI'];
  if (ci == 'true') {
    return true;
  }

  // Allow explicit opt-out via environment variable
  final skipDownload = Platform.environment['ODBC_FAST_SKIP_DOWNLOAD'];
  if (skipDownload == 'true') {
    return true;
  }

  return false;
}

String _getLibraryName(OS os) {
  switch (os) {
    case OS.windows:
      return 'odbc_engine.dll';
    case OS.linux:
      return 'libodbc_engine.so';
    default:
      throw UnsupportedError('OS not supported: $os');
  }
}

/// Returns native library path.
///
/// Search strategy in priority order:
/// 1. Local cache (~/.cache/odbc_fast/)
/// 2. Development build output (native/target/release/)
/// 3. Automatic GitHub Release download (skipped in CI/pub.dev)
/// 4. null (allows tests without native library)
Future<Uri?> _getLibraryPath(
  OS os,
  Architecture arch,
  Uri packageRoot,
  String packageName,
) async {
  final libName = _getLibraryName(os);
  final version = await _extractVersion(
    File.fromUri(packageRoot.resolve('pubspec.yaml')),
  );

  // 1. Check local cache first (versioned)
  final cachedLib = _getCachedLibrary(os, arch, libName, version);
  if (cachedLib != null) {
    return cachedLib;
  }

  // 2. Development: native/target/release/ (workspace target)
  final devPath = packageRoot.resolve('native/target/release/$libName');
  if (File.fromUri(devPath).existsSync()) {
    return devPath;
  }

  // 3. Fallback: native/odbc_engine/target/release/ (target local)
  final devPathLocal =
      packageRoot.resolve('native/odbc_engine/target/release/$libName');
  if (File.fromUri(devPathLocal).existsSync()) {
    return devPathLocal;
  }

  // 4. Download from GitHub Release (production/build only, skipped in CI/pub.dev)
  final downloaded = await _downloadFromGitHub(
    os,
    arch,
    libName,
    packageName,
    packageRoot,
    version,
  );
  if (downloaded != null) {
    return downloaded;
  }

  // Library not found: return null instead of throwing
  // This allows tests to continue without native library
  return null;
}

/// Returns cached library path if available.
/// [version] includes the version in path to avoid reusing a DLL from
/// another version.
Uri? _getCachedLibrary(
  OS os,
  Architecture arch,
  String libName,
  String? version,
) {
  try {
    final cacheDir = _getCacheDirectory(version);
    final platformDir = '${_osToString(os)}_${_archToString(arch)}';
    final cached = File.fromUri(
      cacheDir.resolve('$platformDir/$libName'),
    );

    if (cached.existsSync()) {
      return cached.uri;
    }
  } on FileSystemException {
    // Cache not available, continue
  }
  return null;
}

/// Returns cache directory for native libraries.
///
/// When [version] is not null, uses a version subfolder to avoid loading
/// incompatible DLL versions across package upgrades.
Uri _getCacheDirectory([String? version]) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) {
    throw StateError('Cannot determine user home directory');
  }
  final base = Uri.directory(home).resolve('.cache/odbc_fast/');
  if (version != null && version.isNotEmpty) {
    return base.resolve('$version/');
  }
  return base;
}

/// Downloads native library from GitHub Release.
///
/// Returns downloaded file path, or null on failure.
/// Skips download in CI/pub.dev to avoid timeouts.
Future<Uri?> _downloadFromGitHub(
  OS os,
  Architecture arch,
  String libName,
  String packageName,
  Uri packageRoot,
  String? version,
) async {
  // Do not attempt download in CI/pub.dev environments
  if (_shouldSkipDownload()) {
    print('[odbc_fast] Skipping external download in CI/pub.dev environment');
    return null;
  }

  try {
    if (version == null || version.isEmpty) {
      return null;
    }

    final url = 'https://github.com/cesar-carlos/dart_odbc_fast'
        '/releases/download/v$version/$libName';
    final platform = '${_osToString(os)}_${_archToString(arch)}';

    print('[odbc_fast] Downloading native library for $platform');
    print('[odbc_fast] Version: $version');
    print('[odbc_fast] URL: $url');

    // Create versioned cache directory
    final cacheDirPath = _getCacheDirectory(version).toFilePath();
    final targetDir = Directory(
      '$cacheDirPath${Platform.pathSeparator}$platform',
    );
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final targetFile = File(
      '${targetDir.path}${Platform.pathSeparator}$libName',
    );

    // Download with retry and timeout.
    const maxRetries = 3;
    var attempt = 0;

    while (attempt < maxRetries) {
      HttpClient? client;
      try {
        client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();

        if (response.statusCode == 200) {
          final sink = targetFile.openWrite();
          await response.pipe(sink);
          await sink.flush();
          await sink.close();

          final fileSize = await targetFile.length();
          print('[odbc_fast] [OK] Downloaded successfully');
          print('[odbc_fast]   Path: ${targetFile.path}');
          print('[odbc_fast]   Size: ${_formatBytes(fileSize)}');
          return targetFile.uri;
        }

        if (response.statusCode == 404) {
          print('[odbc_fast] [ERROR] Release not found (HTTP 404)');
          print('[odbc_fast]');
          print('[odbc_fast] This can happen if:');
          print('[odbc_fast]   1. The GitHub release for v$version has not '
              'been created yet');
          print('[odbc_fast]   2. You are developing a new version that is '
              'not released');
          print('[odbc_fast]');
          print('[odbc_fast] To fix this:');
          print('[odbc_fast]   - For production: Create the release at:');
          const releaseUrl =
              'https://github.com/cesar-carlos/dart_odbc_fast/releases';
          print('[odbc_fast]     $releaseUrl');
          print('[odbc_fast]   - For development: Build the library locally:');
          print(
            '[odbc_fast]     cd native/odbc_engine && cargo build --release',
          );
          return null;
        }

        // Other status codes
        attempt++;
        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 100 * (1 << attempt));
          print('[odbc_fast] HTTP ${response.statusCode} - '
              'Retrying $attempt/$maxRetries in ${delay.inSeconds}s...');
          await Future<void>.delayed(delay);
        }
      } on IOException catch (e) {
        attempt++;
        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 100 * (1 << attempt));
          print('[odbc_fast] Network error: $e');
          print('[odbc_fast] Retrying $attempt/$maxRetries in '
              '${delay.inSeconds}s...');
          await Future<void>.delayed(delay);
        } else {
          // Final retry failed
          rethrow;
        }
      } finally {
        client?.close();
      }
    }

    // All retries failed
    print('[odbc_fast] [ERROR] Failed to download after $maxRetries attempts');
    return null;
  } on IOException catch (e) {
    print('[odbc_fast] [ERROR] Download failed');
    print('[odbc_fast]');
    print('[odbc_fast] Error details: $e');
    print('[odbc_fast]');
    print('[odbc_fast] Troubleshooting:');
    print('[odbc_fast]   1. Check your internet connection');
    print('[odbc_fast]   2. Verify the release exists:');
    print(
      '[odbc_fast]      https://github.com/cesar-carlos/dart_odbc_fast/releases',
    );
    print('[odbc_fast]   3. For development, build locally:');
    print('[odbc_fast]      cd native/odbc_engine && cargo build --release');
    return null;
  }
}

/// Formats bytes as human-readable text.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Extracts package version from pubspec.yaml.
Future<String?> _extractVersion(File pubspec) async {
  try {
    final lines = await pubspec.readAsLines();
    for (final line in lines) {
      if (line.startsWith('version:')) {
        final version = line.split(':')[1].trim();
        return version;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// Converts OS enum to cache key string.
String _osToString(OS os) {
  switch (os) {
    case OS.windows:
      return 'windows';
    case OS.linux:
      return 'linux';
    default:
      throw UnsupportedError('OS not supported: $os');
  }
}

/// Converts Architecture enum to cache key string.
String _archToString(Architecture arch) {
  switch (arch) {
    case Architecture.x64:
      return 'x64';
    case Architecture.arm64:
      return 'arm64';
    default:
      throw UnsupportedError('Architecture not supported: $arch');
  }
}
