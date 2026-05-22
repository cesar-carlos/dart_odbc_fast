import 'dart:io';

const _rustSourceRoot = 'native/odbc_engine/src';
const _defPath = 'native/odbc_engine/odbc_exports.def';
const _cbindgenPath = 'native/odbc_engine/cbindgen.toml';
const _headerPath = 'native/odbc_engine/include/odbc_engine.h';
const _dartNativeRoot = 'lib/infrastructure/native';

void main() {
  final missing = <String>[];
  final rustSymbols = _collectRustExportSymbols();

  if (rustSymbols.isEmpty) {
    stderr.writeln('No Rust FFI exports found under $_rustSourceRoot.');
    exitCode = 1;
    return;
  }

  _compareExact(
    _defPath,
    rustSymbols,
    _parseDefExports(_readRequired(_defPath)),
    missing,
  );
  _compareExact(
    _cbindgenPath,
    rustSymbols,
    _parseCbindgenExports(_readRequired(_cbindgenPath)),
    missing,
  );

  final header = File(_headerPath);
  if (header.existsSync()) {
    _compareExact(
      _headerPath,
      rustSymbols,
      _parseHeaderExports(header.readAsStringSync()),
      missing,
    );
  } else {
    stdout.writeln(
      'Skipping generated header check: $_headerPath is not present. '
      'Regenerate via the native build flow when validating generated '
      'artifacts.',
    );
  }

  _compareExact(
    'Dart native lookups under $_dartNativeRoot',
    rustSymbols,
    _collectDartLookups(),
    missing,
  );

  if (missing.isNotEmpty) {
    stderr.writeln('FFI export surfaces are out of sync:');
    for (final item in missing) {
      stderr.writeln('- $item');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'FFI export surfaces are in sync (${rustSymbols.length} symbols).',
  );
}

Set<String> _collectRustExportSymbols() {
  final root = Directory(_rustSourceRoot);
  if (!root.existsSync()) {
    throw StateError('Missing Rust source root: $_rustSourceRoot');
  }

  final symbols = <String>{};
  final exportPattern = RegExp(
    r'#\[(?:unsafe\()?no_mangle(?:\))?\][\s\S]*?'
    r'pub\s+(?:unsafe\s+)?extern\s+"C"\s+fn\s+'
    r'([A-Za-z_][A-Za-z0-9_]*)\s*\(',
  );

  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.rs')) continue;
    final text = entity.readAsStringSync();
    for (final match in exportPattern.allMatches(text)) {
      final symbol = match.group(1);
      if (symbol != null && _isFfiSymbol(symbol)) {
        symbols.add(symbol);
      }
    }
  }

  return symbols;
}

Set<String> _parseDefExports(String text) {
  return text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.split(';').first.trim())
      .where((line) => line.isNotEmpty && line != 'EXPORTS')
      .map((line) => line.split(RegExp(r'\s+')).first)
      .where(_isFfiSymbol)
      .toSet();
}

Set<String> _parseCbindgenExports(String text) {
  final exportStart = text.indexOf('[export]');
  if (exportStart < 0) return {};

  var exportEnd = text.length;
  final sectionPattern = RegExp(r'^\[[^\]]+\]', multiLine: true);
  for (final match in sectionPattern.allMatches(text)) {
    if (match.start > exportStart) {
      exportEnd = match.start;
      break;
    }
  }

  final exportBlock = text.substring(exportStart, exportEnd);
  final includeStart = exportBlock.indexOf('include');
  if (includeStart < 0) return {};
  final arrayStart = exportBlock.indexOf('[', includeStart);
  final arrayEnd = exportBlock.indexOf(']', arrayStart);
  if (arrayStart < 0 || arrayEnd < 0) return {};

  final includeBlock = exportBlock.substring(arrayStart + 1, arrayEnd);
  final quoted = RegExp('"((?:odbc|otel)_[A-Za-z0-9_]+)"');
  return quoted
      .allMatches(includeBlock)
      .map((match) => match.group(1)!)
      .where(_isFfiSymbol)
      .toSet();
}

Set<String> _parseHeaderExports(String text) {
  final pattern = RegExp(r'\b((?:odbc|otel)_[A-Za-z0-9_]+)\s*\(');
  return pattern
      .allMatches(text)
      .map((match) => match.group(1)!)
      .where(_isFfiSymbol)
      .toSet();
}

Set<String> _collectDartLookups() {
  final root = Directory(_dartNativeRoot);
  if (!root.existsSync()) {
    throw StateError('Missing Dart native root: $_dartNativeRoot');
  }

  final lookupPattern = RegExp(
    r'\.lookup(?:<[^()]*>)?\s*\(\s*'
    '''['"]((?:odbc|otel)_[A-Za-z0-9_]+)['"]''',
    multiLine: true,
  );
  final symbols = <String>{};

  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final text = entity.readAsStringSync();
    for (final match in lookupPattern.allMatches(text)) {
      symbols.add(match.group(1)!);
    }
  }

  return symbols;
}

void _compareExact(
  String label,
  Set<String> expected,
  Set<String> actual,
  List<String> issues,
) {
  for (final symbol in _sorted(expected.difference(actual))) {
    issues.add('$label: missing $symbol');
  }
  for (final symbol in _sorted(actual.difference(expected))) {
    issues.add('$label: unexpected $symbol');
  }
}

String _readRequired(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Missing required file: $path');
  }
  return file.readAsStringSync();
}

bool _isFfiSymbol(String symbol) =>
    symbol.startsWith('odbc_') || symbol.startsWith('otel_');

List<String> _sorted(Iterable<String> items) => items.toList()..sort();
