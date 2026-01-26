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
    final libPath = _getLibraryPath(
      targetOS,
      targetArchitecture,
      input.packageRoot,
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
    case OS.macOS:
      return 'libodbc_engine.dylib';
    default:
      throw UnsupportedError('OS not supported: $os');
  }
}

Uri? _getLibraryPath(OS os, Architecture arch, Uri packageRoot) {
  final libName = _getLibraryName(os);

  // Em desenvolvimento: native/target/release/ (workspace target)
  final devPath = packageRoot.resolve('native/target/release/$libName');
  if (File.fromUri(devPath).existsSync()) {
    return devPath;
  }

  // Fallback: native/odbc_engine/target/release/ (target local)
  final devPathLocal = packageRoot.resolve('native/odbc_engine/target/release/$libName');
  if (File.fromUri(devPathLocal).existsSync()) {
    return devPathLocal;
  }

  // Em produção: baixado via GitHub Release ou bundled
  final bundledPath = packageRoot.resolve(_getBundledPath(os, arch, libName));
  if (File.fromUri(bundledPath).existsSync()) {
    return bundledPath;
  }

  // Biblioteca não encontrada - retorna null ao invés de lançar exceção
  // Isso permite que testes continuem mesmo sem a biblioteca
  return null;
}

String _getBundledPath(OS os, Architecture arch, String libName) {
  // Caminho onde os binários bundled serão colocados
  final osStr = os.toString();
  final archStr = arch.toString();
  return 'lib/src/blobs/${osStr}_$archStr/$libName';
}
