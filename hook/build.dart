import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:odbc_fast/src/native_assets/native_library_resolver.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final targetArchitecture = input.config.code.targetArchitecture;
    final libName = libraryNameForOs(targetOS);

    final libPath = await resolveNativeLibraryPath(
      os: targetOS,
      arch: targetArchitecture,
      packageRoot: input.packageRoot,
    );

    // If library is not found, do not add the asset (allows tests without
    // a native library).
    if (libPath == null) {
      return;
    }

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
