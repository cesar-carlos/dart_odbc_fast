import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _runExampleWithoutDsn(String examplePath) {
  return Process.run(
    Platform.resolvedExecutable,
    ['run', examplePath],
    environment: const {
      'ODBC_EXAMPLE_DISABLE_DSN': '1',
      'ODBC_TEST_DSN': '',
      'ODBC_DSN': '',
      'ODBC_ORACLE_REFCURSOR_CALL': '',
    },
    workingDirectory: Directory.current.path,
  );
}

void main() {
  group('opt-in examples', () {
    test(
      'should_skip_columnar_result_encoding_demo_when_dsn_is_disabled',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/columnar_result_encoding_demo.dart',
        );

        expect(result.exitCode, equals(0));
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('Skipping DB-dependent example.'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'should_skip_oracle_ref_cursor_demo_when_call_env_is_missing',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/oracle_ref_cursor_demo.dart',
        );

        expect(result.exitCode, equals(0));
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('ODBC_ORACLE_REFCURSOR_CALL not set'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
