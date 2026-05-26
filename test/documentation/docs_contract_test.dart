import 'dart:io';

import 'package:test/test.dart';

String _readRepoFile(String relativePath) {
  final path = relativePath.split('/').join(Platform.pathSeparator);
  return File(path).readAsStringSync();
}

void main() {
  group('documentation contract', () {
    test('should_keep_capability_docs_aligned_with_current_surface', () {
      final capabilities = _readRepoFile('doc/CAPABILITIES_v3.md');
      final typeMapping = _readRepoFile('doc/notes/TYPE_MAPPING.md');
      final pending = _readRepoFile('doc/Features/PENDING_IMPLEMENTATIONS.md');

      expect(capabilities, contains('**30** `SqlDataType`'));
      expect(capabilities, contains('ResultEncoding.columnar'));
      expect(capabilities, contains('ResultEncoding.columnarCompressed'));
      expect(capabilities, contains('3.1.2'));

      expect(typeMapping, contains('### 3.1.2 Directional capability matrix'));
      expect(
        typeMapping,
        contains('DIRECTED_PARAM|binary_out_inout_not_implemented'),
      );
      expect(typeMapping, contains('ParamValueRefCursorOut'));
      expect(typeMapping, contains('TVP_DESIGN_GATE.md'));

      expect(pending, contains('## 1. Entregue no repo'));
      expect(pending, contains('## 2. Aberto, mas operacional ou opt-in'));
      expect(pending, contains('## 3. Deferido por decisao de produto'));
      expect(pending, contains('Implementado vs certificado em driver live'));
    });

    test('should_document_manual_live_flags_without_making_them_default', () {
      final pending = _readRepoFile('doc/Features/PENDING_IMPLEMENTATIONS.md');
      final testing = _readRepoFile('doc/TESTING.md');

      expect(testing, contains('## Canonical opt-in environment variables'));
      expect(testing, contains('E2E_PG_DIRECTED_OUT'));
      expect(testing, contains('E2E_MSSQL_DIRECTED_OUT'));
      expect(testing, contains('E2E_MSSQL_DIRECTED_OUT_MULTI'));
      expect(testing, contains('E2E_ORACLE_REFCURSOR'));
      expect(testing, contains('ENABLE_MSDTC_XA_TESTS'));
      expect(testing, contains('ENABLE_E2E_TESTS'));
      expect(testing, contains('ODBC_EXAMPLE_DISABLE_DSN'));

      expect(pending, contains('doc/TESTING.md'));
      expect(pending, contains('flags canonicos'));
    });

    test('should_keep_example_readme_links_pointing_to_existing_files', () {
      final exampleReadme = _readRepoFile('example/README.md');
      final dartLinks = RegExp(r'\]\(([^)]+\.dart)\)')
          .allMatches(exampleReadme)
          .map((match) => match.group(1)!)
          .toSet();

      expect(dartLinks, isNotEmpty);
      for (final link in dartLinks) {
        final path = link.split('/').join(Platform.pathSeparator);
        expect(
          File('example${Platform.pathSeparator}$path').existsSync(),
          isTrue,
          reason: 'example/README.md links to missing file "$link"',
        );
      }
    });

    test('should_keep_dsn_free_docs_and_example_tests_in_ci', () {
      final ci = _readRepoFile('.github/workflows/ci.yml');

      expect(ci, contains('ODBC_EXAMPLE_DISABLE_DSN: "1"'));
      expect(ci, contains('dart test test/documentation test/example'));
    });

    test('should_ship_dart_layer_architecture_doc', () {
      // Phase 4 PR4.4: doc/ARCHITECTURE.md mirrors the native engine's
      // architecture doc but documents only the Dart side. Verify the
      // file exists, is referenced from the README, and contains the
      // essential structural anchors so future renames don't silently
      // break the contract.
      final architecture = _readRepoFile('doc/ARCHITECTURE.md');
      expect(architecture, contains('Dart Layer Architecture'));
      expect(architecture, contains('Sealed `OdbcBackend`'));
      expect(architecture, contains('Sub-interfaces of `IOdbcService`'));
      expect(architecture, contains('Repository runners'));
      expect(architecture, contains('Event bus pipeline'));

      final readme = _readRepoFile('README.md');
      expect(readme, contains('doc/ARCHITECTURE.md'));
    });

    test('should_ship_codecov_threshold_and_dependabot_configs', () {
      // PR4.1 + PR4.3: ensure the CI hardening configs ship alongside
      // their docs so future edits don't drop one of them silently.
      final codecov = _readRepoFile('.codecov.yml');
      expect(codecov, contains('target: 80%'));
      expect(codecov, contains('project'));
      expect(codecov, contains('patch'));

      final dependabot = _readRepoFile('.github/dependabot.yml');
      expect(dependabot, contains('package-ecosystem: "pub"'));
      expect(dependabot, contains('package-ecosystem: "cargo"'));
      expect(dependabot, contains('package-ecosystem: "github-actions"'));
      expect(dependabot, contains('weekly'));
    });

    test('should_not_reintroduce_known_stale_feature_phrases', () {
      final paths = [
        'README.md',
        'doc/CAPABILITIES_v3.md',
        'doc/Features/PENDING_IMPLEMENTATIONS.md',
        'doc/notes/TYPE_MAPPING.md',
        'doc/notes/columnar_protocol_sketch.md',
        'doc/TESTING.md',
        'doc/PERFORMANCE.md',
      ];
      final stalePhrases = [
        'Phase 1 pending',
        'Phase 2 pending',
        'Phase 2 wiring',
        'still being rolled in',
        'production results remain row-major only',
        '27-kind',
        '27 total',
      ];

      for (final path in paths) {
        final content = _readRepoFile(path);
        for (final phrase in stalePhrases) {
          expect(
            content,
            isNot(contains(phrase)),
            reason: '$path still contains stale phrase "$phrase"',
          );
        }
      }
    });
  });
}
