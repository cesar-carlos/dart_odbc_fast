import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../../hook/native_library_resolver.dart';

void main() {
  group('extractVersionFromPubspec', () {
    test('should_read_top_level_version', () {
      expect(
        extractVersionFromPubspec('name: odbc_fast\nversion: 4.3.4\n'),
        '4.3.4',
      );
    });

    test('should_ignore_trailing_comment', () {
      expect(
        extractVersionFromPubspec('version: 1.2.3 # release\n'),
        '1.2.3',
      );
    });

    test('should_return_null_when_missing', () {
      expect(extractVersionFromPubspec('name: odbc_fast\n'), isNull);
    });
  });

  group('shouldSkipDownload', () {
    test('should_skip_when_ci_true', () {
      expect(shouldSkipDownload({'CI': 'true'}), isTrue);
    });

    test('should_skip_when_pub_dev_environment', () {
      expect(
        shouldSkipDownload({'PUB_ENVIRONMENT': 'pub.dartlang.org:pub.dev'}),
        isTrue,
      );
    });

    test('should_skip_when_explicit_opt_out', () {
      expect(
        shouldSkipDownload({'ODBC_FAST_SKIP_DOWNLOAD': 'true'}),
        isTrue,
      );
    });

    test('should_not_skip_for_empty_env', () {
      expect(shouldSkipDownload(<String, String>{}), isFalse);
    });
  });

  group('preferLocalBuild', () {
    test('should_be_true_when_env_set', () {
      expect(
        preferLocalBuild({'ODBC_FAST_PREFER_LOCAL_BUILD': 'true'}),
        isTrue,
      );
    });

    test('should_be_false_otherwise', () {
      expect(preferLocalBuild(<String, String>{}), isFalse);
    });
  });

  group('architecture and names', () {
    test('should_treat_only_x64_as_published', () {
      expect(isPublishedArchitecture(Architecture.x64), isTrue);
      expect(isPublishedArchitecture(Architecture.arm64), isFalse);
    });

    test('should_map_library_names', () {
      expect(libraryNameForOs(OS.windows), 'odbc_engine.dll');
      expect(libraryNameForOs(OS.linux), 'libodbc_engine.so');
    });
  });

  group('parseSha256Digest', () {
    test('should_parse_sha256sum_line', () {
      expect(
        parseSha256Digest(
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  '
          'odbc_engine.dll\n',
        ),
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
    });

    test('should_parse_bare_hex', () {
      const hex =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(parseSha256Digest(hex), hex);
    });

    test('should_reject_invalid_digest', () {
      expect(parseSha256Digest('not-a-hash'), isNull);
      expect(parseSha256Digest(''), isNull);
    });
  });

  group('chooseLocalOrCached', () {
    test('should_prefer_local_when_flag_set', () {
      final local = Uri.file('/tmp/local.dll');
      final cached = Uri.file('/tmp/cached.dll');
      expect(
        chooseLocalOrCached(
          local: local,
          cached: cached,
          preferLocal: true,
          modifiedAt: (_) => DateTime.utc(2020),
        ),
        local,
      );
    });

    test('should_prefer_newer_local_over_cache', () {
      final local = Uri.file('/tmp/local.dll');
      final cached = Uri.file('/tmp/cached.dll');
      final localTime = DateTime.utc(2024, 2);
      final cachedTime = DateTime.utc(2024);
      expect(
        chooseLocalOrCached(
          local: local,
          cached: cached,
          modifiedAt: (uri) => uri == local ? localTime : cachedTime,
        ),
        local,
      );
    });

    test('should_prefer_newer_cache_over_local', () {
      final local = Uri.file('/tmp/local.dll');
      final cached = Uri.file('/tmp/cached.dll');
      final localTime = DateTime.utc(2024);
      final cachedTime = DateTime.utc(2024, 2);
      expect(
        chooseLocalOrCached(
          local: local,
          cached: cached,
          modifiedAt: (uri) => uri == cached ? cachedTime : localTime,
        ),
        cached,
      );
    });

    test('should_prefer_local_on_mtime_tie', () {
      final local = Uri.file('/tmp/local.dll');
      final cached = Uri.file('/tmp/cached.dll');
      final stamp = DateTime.utc(2024);
      expect(
        chooseLocalOrCached(
          local: local,
          cached: cached,
          modifiedAt: (_) => stamp,
        ),
        local,
      );
    });
  });

  group('findLocalArtifact', () {
    test('should_find_workspace_release_artifact', () {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_local_');
      addTearDown(() => temp.deleteSync(recursive: true));

      final releaseDir = Directory('${temp.path}/native/target/release')
        ..createSync(recursive: true);
      final lib = File('${releaseDir.path}/odbc_engine.dll')
        ..writeAsStringSync('stub');

      final found = findLocalArtifact(
        packageRoot: temp.uri,
        libName: 'odbc_engine.dll',
      );
      expect(found, isNotNull);
      expect(
        FileSystemEntity.identicalSync(File.fromUri(found!).path, lib.path),
        isTrue,
      );
    });
  });

  group('resolveNativeLibraryPath', () {
    test('should_skip_download_for_arm64_without_local', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_arm_');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 9.9.9\n');

      final resolved = await resolveNativeLibraryPath(
        os: OS.linux,
        arch: Architecture.arm64,
        packageRoot: temp.uri,
        environment: <String, String>{},
        download: _failDownload('download must not run for unpublished arch'),
      );
      expect(resolved, isNull);
    });

    test('should_honor_prefer_local_over_cache', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_pref_');
      addTearDown(() => temp.deleteSync(recursive: true));

      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 1.0.0\n');
      final releaseDir = Directory('${temp.path}/native/target/release')
        ..createSync(recursive: true);
      final local = File('${releaseDir.path}/libodbc_engine.so')
        ..writeAsStringSync('local');

      final home = Directory('${temp.path}/home')..createSync();
      final cacheLib = File(
        '${home.path}/.cache/odbc_fast/1.0.0/linux_x64/libodbc_engine.so',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('cached')
        ..setLastModifiedSync(
          DateTime.now().add(const Duration(hours: 1)),
        );
      expect(cacheLib.existsSync(), isTrue);
      local.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      final resolved = await resolveNativeLibraryPath(
        os: OS.linux,
        arch: Architecture.x64,
        packageRoot: temp.uri,
        environment: {
          'ODBC_FAST_PREFER_LOCAL_BUILD': 'true',
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
        download: _failDownload('download must not run when local exists'),
      );

      expect(resolved, isNotNull);
      expect(
        FileSystemEntity.identicalSync(
          File.fromUri(resolved!).path,
          local.path,
        ),
        isTrue,
      );
    });

    test('should_prefer_newer_cache_when_local_is_stale', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_cache_');
      addTearDown(() => temp.deleteSync(recursive: true));

      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 1.0.0\n');
      final releaseDir = Directory('${temp.path}/native/target/release')
        ..createSync(recursive: true);
      final local = File('${releaseDir.path}/libodbc_engine.so')
        ..writeAsStringSync('local');

      final home = Directory('${temp.path}/home')..createSync();
      final cacheLib = File(
        '${home.path}/.cache/odbc_fast/1.0.0/linux_x64/libodbc_engine.so',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('cached');

      local.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      cacheLib.setLastModifiedSync(DateTime.now());

      final resolved = await resolveNativeLibraryPath(
        os: OS.linux,
        arch: Architecture.x64,
        packageRoot: temp.uri,
        environment: {
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
        download: _failDownload(
          'download must not run when cache/local exist',
        ),
      );

      expect(resolved, isNotNull);
      expect(
        FileSystemEntity.identicalSync(
          File.fromUri(resolved!).path,
          cacheLib.path,
        ),
        isTrue,
      );
    });

    test('should_invoke_download_when_no_local_or_cache', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_dl_');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 2.0.0\n');
      final home = Directory('${temp.path}/home')..createSync();
      final downloaded = File('${temp.path}/downloaded.so')
        ..writeAsStringSync('from-github');

      final calls =
          <({OS os, Architecture arch, String libName, String? version})>[];
      final resolved = await resolveNativeLibraryPath(
        os: OS.linux,
        arch: Architecture.x64,
        packageRoot: temp.uri,
        environment: {
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
        download: _recordingDownload(calls, downloaded.uri),
      );

      expect(calls, hasLength(1));
      expect(calls.single.os, OS.linux);
      expect(calls.single.arch, Architecture.x64);
      expect(calls.single.libName, 'libodbc_engine.so');
      expect(calls.single.version, '2.0.0');
      expect(resolved, isNotNull);
      expect(
        FileSystemEntity.identicalSync(
          File.fromUri(resolved!).path,
          downloaded.path,
        ),
        isTrue,
      );
    });

    test('should_skip_download_when_ODBC_FAST_SKIP_DOWNLOAD', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_skip_');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 2.0.0\n');
      final home = Directory('${temp.path}/home')..createSync();

      final resolved = await resolveNativeLibraryPath(
        os: OS.linux,
        arch: Architecture.x64,
        packageRoot: temp.uri,
        environment: {
          'ODBC_FAST_SKIP_DOWNLOAD': 'true',
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
        download: _failDownload('download must not run when skip is set'),
      );
      expect(resolved, isNull);
    });

    test('should_skip_download_when_CI_true', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_ci_');
      addTearDown(() => temp.deleteSync(recursive: true));
      File('${temp.path}/pubspec.yaml').writeAsStringSync('version: 2.0.0\n');
      final home = Directory('${temp.path}/home')..createSync();

      final resolved = await resolveNativeLibraryPath(
        os: OS.windows,
        arch: Architecture.x64,
        packageRoot: temp.uri,
        environment: {
          'CI': 'true',
          'HOME': home.path,
          'USERPROFILE': home.path,
        },
        download: _failDownload('download must not run when CI=true'),
      );
      expect(resolved, isNull);
    });
  });

  group('verifyFileSha256', () {
    test('should_verify_matching_digest', () async {
      final temp = Directory.systemTemp.createTempSync('odbc_hook_sha_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/blob.bin')..writeAsStringSync('abc');
      final hex = await fileSha256Hex(file);
      expect(
        await verifyFileSha256(file: file, expectedHex: hex),
        isTrue,
      );
      expect(
        await verifyFileSha256(file: file, expectedHex: '0' * 64),
        isFalse,
      );
    });

    test('should_reject_sha256_mismatch_for_download_contract', () async {
      // Mirrors downloadFromGitHub: when sidecar digest mismatches, the
      // downloaded file must not be accepted.
      final temp = Directory.systemTemp.createTempSync('odbc_hook_sha_bad_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/libodbc_engine.so')
        ..writeAsStringSync('payload');
      final sidecar = parseSha256Digest('${'a' * 64}  libodbc_engine.so\n');
      expect(sidecar, isNotNull);
      expect(
        await verifyFileSha256(file: file, expectedHex: sidecar!),
        isFalse,
      );
    });
  });

  group('githubReleaseAssetUrl', () {
    test('should_build_release_url', () {
      expect(
        githubReleaseAssetUrl(version: '4.3.4', libName: 'odbc_engine.dll'),
        'https://github.com/cesar-carlos/dart_odbc_fast'
        '/releases/download/v4.3.4/odbc_engine.dll',
      );
    });
  });
}

Future<Uri?> Function({
  required OS os,
  required Architecture arch,
  required String libName,
  required String? version,
}) _failDownload(String message) {
  return ({
    required OS os,
    required Architecture arch,
    required String libName,
    required String? version,
  }) async {
    fail(message);
  };
}

Future<Uri?> Function({
  required OS os,
  required Architecture arch,
  required String libName,
  required String? version,
}) _recordingDownload(
  List<({OS os, Architecture arch, String libName, String? version})> calls,
  Uri result,
) {
  return ({
    required OS os,
    required Architecture arch,
    required String libName,
    required String? version,
  }) async {
    calls.add((os: os, arch: arch, libName: libName, version: version));
    return result;
  };
}
