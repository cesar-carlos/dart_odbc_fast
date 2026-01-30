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

    // Define nome da biblioteca por plataforma
    final libName = _getLibraryName(targetOS);

    // Caminho da biblioteca compilada
    final libPath = await _getLibraryPath(
      targetOS,
      targetArchitecture,
      input.packageRoot,
      packageName,
    );

    // Se a biblioteca não foi encontrada, não adiciona o asset
    // (permite que testes continuem mesmo sem a biblioteca)
    if (libPath == null) {
      return;
    }

    // Registra o asset nativo
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

/// Verifica se deve pular download externo (CI/pub.dev environments).
bool _shouldSkipDownload() {
  // Pular download se PUB_ENVIRONMENT estiver definido (indicando pub.dev)
  final pubEnv = Platform.environment['PUB_ENVIRONMENT'];
  if (pubEnv != null && pubEnv.contains('pub.dev')) {
    return true;
  }

  // Pular download se CI estiver definido
  final ci = Platform.environment['CI'];
  if (ci == 'true') {
    return true;
  }

  // Permitir desabilitar explicitamente via variável de ambiente
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

/// Retorna o caminho da biblioteca nativa.
///
/// Estratégia de busca em ordem de prioridade:
/// 1. Cache local (~/.cache/odbc_fast/)
/// 2. Desenvolvimento (native/target/release/)
/// 3. Download automático da GitHub Release (pulado em CI/pub.dev)
/// 4. null (permite testes sem biblioteca)
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

  // 1. Verificar cache local primeiro (por versão)
  final cachedLib = _getCachedLibrary(os, arch, libName, version);
  if (cachedLib != null) {
    return cachedLib;
  }

  // 2. Desenvolvimento: native/target/release/ (workspace target)
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

  // 4. Baixar da GitHub Release (apenas em produção/build, pulado em CI/pub.dev)
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

  // Biblioteca não encontrada - retorna null ao invés de lançar exceção
  // Isso permite que testes continuem mesmo sem a biblioteca
  return null;
}

/// Retorna o caminho da biblioteca no cache local, se existir.
/// [version] inclui a versão no path para evitar reutilizar DLL de outra versão
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
    // Cache não disponível, continuar
  }
  return null;
}

/// Retorna o diretório de cache para bibliotecas nativas.
///
/// [version] quando não null, usa subpasta por versão para evitar DLL
/// incompatível entre versões diferentes do pacote.
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

/// Baixa a biblioteca nativa da GitHub Release.
///
/// Retorna o caminho do arquivo baixado, ou null se falhar.
/// Pula download em ambientes de CI/pub.dev para evitar timeouts.
Future<Uri?> _downloadFromGitHub(
  OS os,
  Architecture arch,
  String libName,
  String packageName,
  Uri packageRoot,
  String? version,
) async {
  // Não tentar download em ambientes de CI/pub.dev
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

    // Criar diretório de cache (por versão)
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

    // Download com retry e timeout
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
          print('[odbc_fast] ✓ Downloaded successfully');
          print('[odbc_fast]   Path: ${targetFile.path}');
          print('[odbc_fast]   Size: ${_formatBytes(fileSize)}');
          return targetFile.uri;
        }

        if (response.statusCode == 404) {
          print('[odbc_fast] ✗ Release not found (HTTP 404)');
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
    print('[odbc_fast] ✗ Failed to download after $maxRetries attempts');
    return null;
  } on IOException catch (e) {
    print('[odbc_fast] ✗ Download failed');
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

/// Formata bytes para representação humana.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Extrai a versão do pubspec.yaml.
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

/// Converte OS para string usada no cache.
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

/// Converte Architecture para string usada no cache.
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
