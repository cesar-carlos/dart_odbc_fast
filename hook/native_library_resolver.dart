import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';

/// Architectures published as GitHub Release assets today
/// (flat names, x64 only).
bool isPublishedArchitecture(Architecture arch) => arch == Architecture.x64;

/// Skips GitHub download in CI, pub.dev, or when explicitly opted out.
bool shouldSkipDownload([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;

  final pubEnv = env['PUB_ENVIRONMENT'];
  if (pubEnv != null && pubEnv.contains('pub.dev')) {
    return true;
  }

  if (env['CI'] == 'true') {
    return true;
  }

  if (env['ODBC_FAST_SKIP_DOWNLOAD'] == 'true') {
    return true;
  }

  return false;
}

/// When true, a local release artifact wins over cache even if older.
bool preferLocalBuild([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  return env['ODBC_FAST_PREFER_LOCAL_BUILD'] == 'true';
}

String libraryNameForOs(OS os) {
  switch (os) {
    case OS.windows:
      return 'odbc_engine.dll';
    case OS.linux:
      return 'libodbc_engine.so';
    default:
      throw UnsupportedError('OS not supported: $os');
  }
}

String osToCacheKey(OS os) {
  switch (os) {
    case OS.windows:
      return 'windows';
    case OS.linux:
      return 'linux';
    default:
      throw UnsupportedError('OS not supported: $os');
  }
}

String archToCacheKey(Architecture arch) {
  switch (arch) {
    case Architecture.x64:
      return 'x64';
    case Architecture.arm64:
      return 'arm64';
    default:
      throw UnsupportedError('Architecture not supported: $arch');
  }
}

/// Extracts the package version from pubspec.yaml contents.
///
/// Reads the first top-level `version:` line (ignores indented keys).
String? extractVersionFromPubspec(String contents) {
  for (final line in contents.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.startsWith('version:')) {
      final value = trimmed.substring('version:'.length).trim();
      if (value.isEmpty) {
        return null;
      }
      // Drop trailing comments: `version: 1.2.3 # note`
      final withoutComment = value.split('#').first.trim();
      return withoutComment.isEmpty ? null : withoutComment;
    }
  }
  return null;
}

Future<String?> extractVersion(File pubspec) async {
  try {
    return extractVersionFromPubspec(await pubspec.readAsString());
  } on FileSystemException {
    return null;
  }
}

/// Cache root: `~/.cache/odbc_fast/[version]/`.
Uri cacheDirectoryFor(String home, [String? version]) {
  final base = Uri.directory(home).resolve('.cache/odbc_fast/');
  if (version != null && version.isNotEmpty) {
    return base.resolve('$version/');
  }
  return base;
}

Uri cacheDirectory([String? version]) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) {
    throw StateError('Cannot determine user home directory');
  }
  return cacheDirectoryFor(home, version);
}

Uri? cachedLibraryUri({
  required OS os,
  required Architecture arch,
  required String libName,
  required String? version,
  Map<String, String>? environment,
}) {
  if (!isPublishedArchitecture(arch)) {
    return null;
  }

  try {
    final env = environment ?? Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null) {
      return null;
    }
    final cacheDir = cacheDirectoryFor(home, version);
    final platformDir = '${osToCacheKey(os)}_${archToCacheKey(arch)}';
    final cached = File.fromUri(cacheDir.resolve('$platformDir/$libName'));
    if (cached.existsSync()) {
      return cached.uri;
    }
  } on FileSystemException {
    // Cache not available.
  }
  return null;
}

/// Workspace then crate-local release paths under [packageRoot].
List<Uri> localArtifactCandidates({
  required Uri packageRoot,
  required String libName,
}) {
  return [
    packageRoot.resolve('native/target/release/$libName'),
    packageRoot.resolve('native/odbc_engine/target/release/$libName'),
  ];
}

Uri? findLocalArtifact({
  required Uri packageRoot,
  required String libName,
}) {
  for (final path in localArtifactCandidates(
    packageRoot: packageRoot,
    libName: libName,
  )) {
    if (File.fromUri(path).existsSync()) {
      return path;
    }
  }
  return null;
}

/// Picks between [local] and [cached] using mtime and [preferLocal].
///
/// Preference:
/// 1. `ODBC_FAST_PREFER_LOCAL_BUILD=true` + local → local
/// 2. Both exist → newer mtime wins (local on tie)
/// 3. Whichever exists
Uri? chooseLocalOrCached({
  required Uri? local,
  required Uri? cached,
  bool preferLocal = false,
  DateTime Function(Uri uri)? modifiedAt,
}) {
  DateTime mtime(Uri uri) {
    if (modifiedAt != null) {
      return modifiedAt(uri);
    }
    return File.fromUri(uri).lastModifiedSync();
  }

  if (preferLocal && local != null) {
    return local;
  }

  if (local != null && cached != null) {
    final localTime = mtime(local);
    final cachedTime = mtime(cached);
    if (!localTime.isBefore(cachedTime)) {
      return local;
    }
    return cached;
  }

  return cached ?? local;
}

/// Parses `sha256sum` output (`<hex>  <filename>`) or a bare hex digest.
String? parseSha256Digest(String contents) {
  final trimmed = contents.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
  if (firstLine.isEmpty) {
    return null;
  }
  final hex = firstLine.split(RegExp(r'\s+')).first.toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    return null;
  }
  return hex;
}

Future<String> fileSha256Hex(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<bool> verifyFileSha256({
  required File file,
  required String expectedHex,
}) async {
  final actual = await fileSha256Hex(file);
  return actual.toLowerCase() == expectedHex.toLowerCase();
}

String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String githubReleaseAssetUrl({
  required String version,
  required String libName,
}) {
  return 'https://github.com/cesar-carlos/dart_odbc_fast'
      '/releases/download/v$version/$libName';
}

/// Resolves the native library path for the build hook.
///
/// Order: prefer-local / newer-local → cache → local → GitHub download.
Future<Uri?> resolveNativeLibraryPath({
  required OS os,
  required Architecture arch,
  required Uri packageRoot,
  Map<String, String>? environment,
  Future<Uri?> Function({
    required OS os,
    required Architecture arch,
    required String libName,
    required String? version,
  })? download,
}) async {
  final env = environment ?? Platform.environment;
  final libName = libraryNameForOs(os);
  final version = await extractVersion(
    File.fromUri(packageRoot.resolve('pubspec.yaml')),
  );

  final local = findLocalArtifact(packageRoot: packageRoot, libName: libName);
  final cached = cachedLibraryUri(
    os: os,
    arch: arch,
    libName: libName,
    version: version,
    environment: env,
  );

  final chosen = chooseLocalOrCached(
    local: local,
    cached: cached,
    preferLocal: preferLocalBuild(env),
  );
  if (chosen != null) {
    if (chosen == local) {
      stdout.writeln(
        '[odbc_fast] Using local build artifact: ${chosen.toFilePath()}',
      );
    } else {
      stdout.writeln(
        '[odbc_fast] Using cached native library: ${chosen.toFilePath()}',
      );
    }
    return chosen;
  }

  if (!isPublishedArchitecture(arch)) {
    stdout.writeln(
      '[odbc_fast] No prebuilt release for ${osToCacheKey(os)}_'
      '${archToCacheKey(arch)}; only x64 GitHub assets are published. '
      'Build locally: cd native && cargo build --release',
    );
    return null;
  }

  if (shouldSkipDownload(env)) {
    stdout.writeln(
      '[odbc_fast] Skipping external download in CI/pub.dev environment',
    );
    return null;
  }

  final downloadFn = download ?? downloadFromGitHub;
  return downloadFn(
    os: os,
    arch: arch,
    libName: libName,
    version: version,
  );
}

/// Downloads the native library from GitHub Releases and verifies SHA-256 when
/// a sidecar `.sha256` asset is available.
Future<Uri?> downloadFromGitHub({
  required OS os,
  required Architecture arch,
  required String libName,
  required String? version,
}) async {
  try {
    if (version == null || version.isEmpty) {
      return null;
    }
    if (!isPublishedArchitecture(arch)) {
      return null;
    }

    final url = githubReleaseAssetUrl(version: version, libName: libName);
    final platform = '${osToCacheKey(os)}_${archToCacheKey(arch)}';

    stdout
      ..writeln('[odbc_fast] Downloading native library for $platform')
      ..writeln('[odbc_fast] Version: $version')
      ..writeln('[odbc_fast] URL: $url');

    final cacheDirPath = cacheDirectory(version).toFilePath();
    final targetDir = Directory(
      '$cacheDirPath${Platform.pathSeparator}$platform',
    );
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final targetFile = File(
      '${targetDir.path}${Platform.pathSeparator}$libName',
    );
    final checksumUrl = '$url.sha256';

    const maxRetries = 3;
    var attempt = 0;

    while (attempt < maxRetries) {
      HttpClient? client;
      try {
        client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30)
          ..idleTimeout = const Duration(seconds: 60);

        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();

        if (response.statusCode == 200) {
          final sink = targetFile.openWrite();
          await response.pipe(sink);
          await sink.flush();
          await sink.close();

          final checksumOk = await _verifyDownloadedChecksum(
            client: client,
            checksumUrl: checksumUrl,
            targetFile: targetFile,
          );
          if (!checksumOk) {
            if (targetFile.existsSync()) {
              targetFile.deleteSync();
            }
            return null;
          }

          final fileSize = await targetFile.length();
          stdout
            ..writeln('[odbc_fast] [OK] Downloaded successfully')
            ..writeln('[odbc_fast]   Path: ${targetFile.path}')
            ..writeln('[odbc_fast]   Size: ${formatBytes(fileSize)}');
          return targetFile.uri;
        }

        if (response.statusCode == 404) {
          await response.drain<void>();
          stdout
            ..writeln('[odbc_fast] [ERROR] Release not found (HTTP 404)')
            ..writeln('[odbc_fast]')
            ..writeln('[odbc_fast] This can happen if:')
            ..writeln(
              '[odbc_fast]   1. The GitHub release for v$version has not '
              'been created yet',
            )
            ..writeln(
              '[odbc_fast]   2. You are developing a new version that is '
              'not released',
            )
            ..writeln('[odbc_fast]')
            ..writeln('[odbc_fast] To fix this:')
            ..writeln(
              '[odbc_fast]   - For production: Create the release at:',
            );
          const releaseUrl =
              'https://github.com/cesar-carlos/dart_odbc_fast/releases';
          stdout
            ..writeln('[odbc_fast]     $releaseUrl')
            ..writeln(
              '[odbc_fast]   - For development: Build the library locally:',
            )
            ..writeln(
              '[odbc_fast]     cd native && cargo build --release',
            );
          return null;
        }

        await response.drain<void>();
        attempt++;
        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 100 * (1 << attempt));
          stdout.writeln(
            '[odbc_fast] HTTP ${response.statusCode} - '
            'Retrying $attempt/$maxRetries in ${delay.inMilliseconds}ms...',
          );
          await Future<void>.delayed(delay);
        }
      } on IOException catch (e) {
        attempt++;
        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 100 * (1 << attempt));
          stdout
            ..writeln('[odbc_fast] Network error: $e')
            ..writeln(
              '[odbc_fast] Retrying $attempt/$maxRetries in '
              '${delay.inMilliseconds}ms...',
            );
          await Future<void>.delayed(delay);
        } else {
          rethrow;
        }
      } finally {
        client?.close();
      }
    }

    stdout.writeln(
      '[odbc_fast] [ERROR] Failed to download after $maxRetries attempts',
    );
    return null;
  } on IOException catch (e) {
    stdout
      ..writeln('[odbc_fast] [ERROR] Download failed')
      ..writeln('[odbc_fast]')
      ..writeln('[odbc_fast] Error details: $e')
      ..writeln('[odbc_fast]')
      ..writeln('[odbc_fast] Troubleshooting:')
      ..writeln('[odbc_fast]   1. Check your internet connection')
      ..writeln('[odbc_fast]   2. Verify the release exists:')
      ..writeln(
        '[odbc_fast]      '
        'https://github.com/cesar-carlos/dart_odbc_fast/releases',
      )
      ..writeln('[odbc_fast]   3. For development, build locally:')
      ..writeln('[odbc_fast]      cd native && cargo build --release');
    return null;
  }
}

Future<bool> _verifyDownloadedChecksum({
  required HttpClient client,
  required String checksumUrl,
  required File targetFile,
}) async {
  try {
    final request = await client.getUrl(Uri.parse(checksumUrl));
    final response = await request.close();
    if (response.statusCode == 404) {
      await response.drain<void>();
      stdout.writeln(
        '[odbc_fast] [WARN] No .sha256 sidecar at $checksumUrl; '
        'accepting download without integrity check (legacy release)',
      );
      return true;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      stdout.writeln(
        '[odbc_fast] [ERROR] Checksum fetch failed '
        '(HTTP ${response.statusCode}) for $checksumUrl',
      );
      return false;
    }

    final body = await utf8.decoder.bind(response).join();
    final expected = parseSha256Digest(body);
    if (expected == null) {
      stdout.writeln(
        '[odbc_fast] [ERROR] Invalid checksum file contents at $checksumUrl',
      );
      return false;
    }

    final ok = await verifyFileSha256(
      file: targetFile,
      expectedHex: expected,
    );
    if (!ok) {
      stdout.writeln(
        '[odbc_fast] [ERROR] SHA-256 mismatch for ${targetFile.path}',
      );
      return false;
    }

    stdout.writeln('[odbc_fast] [OK] SHA-256 verified');
    return true;
  } on IOException catch (e) {
    stdout.writeln('[odbc_fast] [ERROR] Checksum verification failed: $e');
    return false;
  }
}
