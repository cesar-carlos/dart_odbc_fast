// Native Assets / library resolution demo (no database required).
// Run: dart run example/native_assets_resolution_demo.dart
//
// Documents how `hook/build.dart` and `library_loader.dart` cooperate to find
// `odbc_engine`, and probes the local + cache locations used in development.
//
// Env vars (hook):
//   ODBC_FAST_PREFER_LOCAL_BUILD=true  — prefer local release over cache
//   ODBC_FAST_SKIP_DOWNLOAD=true       — never download from GitHub Releases
// See also: doc/BUILD.md

import 'dart:ffi';
import 'dart:io';

import 'package:odbc_fast/odbc_fast.dart';
import 'package:odbc_fast/odbc_fast_native.dart';

void main() {
  AppLogger.initialize();

  _line('=== Native library resolution ===');
  _line('Runtime order (library_loader):');
  _line('  1. preferred on-disk file (local vs ~/.cache, same policy as hook)');
  _line('  2. package:odbc_fast/<lib> (Native Assets via hook)');
  _line('  3. system PATH / LD_LIBRARY_PATH');
  _line('');
  _line('Hook order (hook/build.dart):');
  _line('  prefer-local / newer-local -> cache -> local -> GitHub (x64)');
  _line('');

  final preferLocal = preferLocalOdbcEngineBuild();
  final skipDownload =
      Platform.environment['ODBC_FAST_SKIP_DOWNLOAD'] == 'true';
  _line('ODBC_FAST_PREFER_LOCAL_BUILD=$preferLocal');
  _line('ODBC_FAST_SKIP_DOWNLOAD=$skipDownload');
  _line('');

  final root = _findPackageRoot();
  final preferred = root == null
      ? null
      : resolvePreferredOdbcEngineFilePath(
          cwd: Directory.current.path,
          packageRoot: root,
        );
  if (preferred != null) {
    _line('Preferred on-disk path: $preferred');
  } else {
    _line('Preferred on-disk path: (none)');
  }
  if (root == null) {
    _line('Could not locate package root (pubspec.yaml).');
    return;
  }

  final libName = _libraryName();
  final version = _readPackageVersion(root);
  _line('Package root : $root');
  _line('Library name : $libName');
  _line('Version      : ${version ?? "(unknown)"}');
  _line('');

  _line('--- Candidate paths ---');
  for (final path in _localCandidates(root, libName)) {
    _logPath('local', path);
  }

  final cachePath = _cachedLibraryPath(version, libName);
  if (cachePath != null) {
    _logPath('cache', cachePath);
  } else {
    _line('cache : (home directory unavailable)');
  }
  _line('');

  _line('--- Load probe (OdbcNative) ---');
  try {
    final native = OdbcNative();
    if (!native.init()) {
      _line(
        'odbc_init failed - binary may be missing. Build with:\n'
        '  cd native && cargo build --release\n'
        'or re-run: dart pub get (downloads x64 release assets).',
      );
      return;
    }

    final versionMap = native.getVersion();
    if (versionMap != null && versionMap.isNotEmpty) {
      _line('Native engine loaded: $versionMap');
    } else {
      _line('Native engine loaded (version string unavailable).');
    }
    native.dispose();
  } on Object catch (e) {
    _line('Failed to load native library: $e');
    _line(
      'Build locally: cd native && cargo build --release\n'
      'Docs: doc/BUILD.md',
    );
  }
}

void _line(String message) {
  // CLI demos need stdout for users and Process.run smoke tests; AppLogger
  // alone uses dart:developer and is invisible to captured output.
  print(message);
  AppLogger.info(message);
}

String _libraryName() {
  if (Platform.isWindows) {
    return 'odbc_engine.dll';
  }
  if (Platform.isLinux) {
    return 'libodbc_engine.so';
  }
  return 'unsupported_${Platform.operatingSystem}';
}

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

String? _readPackageVersion(String root) {
  final pubspec = File('$root${Platform.pathSeparator}pubspec.yaml');
  if (!pubspec.existsSync()) {
    return null;
  }
  for (final line in pubspec.readAsLinesSync()) {
    final trimmed = line.trimRight();
    if (trimmed.startsWith('version:')) {
      final value = trimmed.substring('version:'.length).trim();
      return value.split('#').first.trim();
    }
  }
  return null;
}

List<String> _localCandidates(String root, String libName) {
  final sep = Platform.pathSeparator;
  return [
    '$root${sep}native${sep}target${sep}release$sep$libName',
    '$root${sep}native${sep}odbc_engine${sep}target${sep}release$sep$libName',
  ];
}

String? _cachedLibraryPath(String? version, String libName) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) {
    return null;
  }

  final os = Platform.isWindows
      ? 'windows'
      : Platform.isLinux
          ? 'linux'
          : Platform.operatingSystem;
  final arch = switch (Abi.current()) {
    Abi.androidArm64 ||
    Abi.fuchsiaArm64 ||
    Abi.iosArm64 ||
    Abi.linuxArm64 ||
    Abi.macosArm64 ||
    Abi.windowsArm64 =>
      'arm64',
    _ => 'x64',
  };
  final sep = Platform.pathSeparator;
  final versionSeg =
      (version != null && version.isNotEmpty) ? '$version$sep' : '';
  return '$home$sep.cache${sep}odbc_fast$sep$versionSeg'
      '${os}_$arch$sep$libName';
}

void _logPath(String label, String path) {
  final file = File(path);
  if (file.existsSync()) {
    final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);
    _line('$label : FOUND ($sizeKb KB) - $path');
  } else {
    _line('$label : missing - $path');
  }
}
