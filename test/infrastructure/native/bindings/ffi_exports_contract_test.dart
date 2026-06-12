import 'dart:io';

import 'package:test/test.dart';

/// Parses `native/odbc_engine/odbc_exports.def` and verifies every exported
/// symbol has a matching `lookup` in Dart FFI sources.
void main() {
  group('FFI exports contract', () {
    late List<String> exportedSymbols;
    late Set<String> dartLookups;

    setUp(() {
      final defPath = 'native${Platform.pathSeparator}odbc_engine'
          '${Platform.pathSeparator}odbc_exports.def';
      final def = File(defPath).readAsStringSync();
      exportedSymbols = def
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && line != 'EXPORTS')
          .toList();

      final bindingRoot = Directory(
        'lib${Platform.pathSeparator}infrastructure'
        '${Platform.pathSeparator}native',
      );
      final dartSources = bindingRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.readAsStringSync());

      final combined = dartSources.join('\n');
      final lookupPattern = RegExp(
        r"lookup(?:<[\s\S]*?>)?\(\s*'([^']+)'",
      );
      dartLookups = {
        for (final match in lookupPattern.allMatches(combined)) match.group(1)!,
      };
    });

    test('should_export_at_least_ninety_one_native_symbols', () {
      expect(exportedSymbols.length, greaterThanOrEqualTo(91));
    });

    test('should_map_every_odbc_symbol_to_dart_lookup', () {
      final odbcSymbols =
          exportedSymbols.where((symbol) => symbol.startsWith('odbc_'));

      expect(odbcSymbols, isNotEmpty);
      for (final symbol in odbcSymbols) {
        expect(
          dartLookups,
          contains(symbol),
          reason:
              '$symbol is listed in odbc_exports.def but has no Dart lookup '
              '(expected in odbc_bindings_*.dart, ffi_buffer_helper.dart, '
              'or columnar_decompress_ffi.dart)',
        );
      }
    });

    test('should_map_otel_symbols_to_separate_dart_module', () {
      final otelSymbols =
          exportedSymbols.where((symbol) => symbol.startsWith('otel_'));

      expect(otelSymbols, hasLength(6));
      for (final symbol in otelSymbols) {
        expect(
          dartLookups,
          contains(symbol),
          reason:
              '$symbol must resolve via opentelemetry_ffi.dart, '
              'not OdbcBindings',
        );
      }
    });

    test('should_resolve_release_buffer_outside_odbc_bindings', () {
      expect(exportedSymbols, contains('odbc_release_buffer'));
      expect(dartLookups, contains('odbc_release_buffer'));

      final bindingsOnly = Directory(
        'lib${Platform.pathSeparator}infrastructure'
        '${Platform.pathSeparator}native'
        '${Platform.pathSeparator}bindings',
      )
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => file.readAsStringSync())
          .join('\n');

      expect(bindingsOnly, isNot(contains("lookup('odbc_release_buffer'")));
      expect(
        File(
          'lib${Platform.pathSeparator}infrastructure'
          '${Platform.pathSeparator}native'
          '${Platform.pathSeparator}bindings'
          '${Platform.pathSeparator}ffi_buffer_helper.dart',
        ).readAsStringSync(),
        contains('odbc_release_buffer'),
      );
    });
  });
}
