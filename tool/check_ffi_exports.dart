import 'dart:io';

const _requiredSymbols = <String>[
  'odbc_execute_async_params',
  'odbc_exec_query_params_options',
];

const _surfaces = <String>[
  'native/odbc_engine/odbc_exports.def',
  'native/odbc_engine/cbindgen.toml',
  'native/doc/ffi_api.md',
  'lib/infrastructure/native/bindings/odbc_bindings.dart',
  'lib/infrastructure/native/bindings/odbc_native.dart',
];

void main() {
  final missing = <String>[];

  for (final surface in _surfaces) {
    final file = File(surface);
    if (!file.existsSync()) {
      missing.add('$surface: file is missing');
      continue;
    }

    final text = file.readAsStringSync();
    for (final symbol in _requiredSymbols) {
      if (!text.contains(symbol)) {
        missing.add('$surface: missing $symbol');
      }
    }
  }

  final header = File('native/odbc_engine/include/odbc_engine.h');
  if (header.existsSync()) {
    final text = header.readAsStringSync();
    for (final symbol in _requiredSymbols) {
      if (!text.contains(symbol)) {
        missing.add('${header.path}: missing $symbol');
      }
    }
  } else {
    stdout.writeln(
      'Skipping generated header check: native/odbc_engine/include/'
      'odbc_engine.h is not present. Regenerate via project build flow when '
      'validating generated artifacts.',
    );
  }

  if (missing.isNotEmpty) {
    stderr.writeln('FFI export surfaces are out of sync:');
    for (final item in missing) {
      stderr.writeln('- $item');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('FFI export surfaces are in sync.');
}
