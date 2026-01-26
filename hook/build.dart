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
/// 3. Download automático da GitHub Release
/// 4. null (permite testes sem biblioteca)
Future<Uri?> _getLibraryPath(
  OS os,
  Architecture arch,
  Uri packageRoot,
  String packageName,
) async {
  final libName = _getLibraryName(os);

  // 1. Verificar cache local primeiro
  final cachedLib = _getCachedLibrary(os, arch, libName);
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

  // 4. Baixar da GitHub Release (apenas em produção/build)
  // Não baixa durante desenvolvimento se não encontrar em dev paths
  final downloaded = await _downloadFromGitHub(os, arch, libName, packageName);
  if (downloaded != null) {
    return downloaded;
  }

  // Biblioteca não encontrada - retorna null ao invés de lançar exceção
  // Isso permite que testes continuem mesmo sem a biblioteca
  return null;
}

/// Retorna o caminho da biblioteca no cache local, se existir.
Uri? _getCachedLibrary(OS os, Architecture arch, String libName) {
  try {
    final cacheDir = _getCacheDirectory();
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
Uri _getCacheDirectory() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null) {
    throw StateError('Cannot determine user home directory');
  }
  return Uri.directory(home).resolve('.cache/odbc_fast/');
}

/// Baixa a biblioteca nativa da GitHub Release.
///
/// Retorna o caminho do arquivo baixado, ou null se falhar.
Future<Uri?> _downloadFromGitHub(
  OS os,
  Architecture arch,
  String libName,
  String packageName,
) async {
  try {
    // Ler versão do pubspec.yaml
    final pubspec = File.fromUri(
      Uri.file(
        '${Directory.current.path}${Platform.pathSeparator}pubspec.yaml',
      ),
    );
    if (!pubspec.existsSync()) {
      return null;
    }

    final version = await _extractVersion(pubspec);
    if (version == null) {
      return null;
    }

    final url = 'https://github.com/cesar-carlos/dart_odbc_fast'
        '/releases/download/v$version/$libName';

    print('[odbc_fast] Downloading native library from $url');

    // Criar diretório de cache
    final cacheDirPath = _getCacheDirectory().toFilePath();
    final platformDir = '${_osToString(os)}_${_archToString(arch)}';
    final targetDir = Directory(
      '$cacheDirPath${Platform.pathSeparator}$platformDir',
    );
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    final targetFile = File(
      '${targetDir.path}${Platform.pathSeparator}$libName',
    );

    // Download
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != 200) {
        print('[odbc_fast] Failed to download: HTTP ${response.statusCode}');
        return null;
      }

      final sink = targetFile.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();

      print('[odbc_fast] Downloaded to ${targetFile.path}');
      return targetFile.uri;
    } finally {
      client.close();
    }
  } on IOException catch (e) {
    print('[odbc_fast] Download failed: $e');
    return null;
  }
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
