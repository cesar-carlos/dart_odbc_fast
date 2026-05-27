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

    test(
      'should_skip_stream_query_named_demo_when_dsn_is_disabled',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/stream_query_named_demo.dart',
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
      'should_skip_backpressure_modes_demo_when_dsn_is_disabled',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/backpressure_modes_demo.dart',
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
      'should_run_sub_interfaces_migration_demo_in_describe_only_mode',
      () async {
        // The demo doesn't connect to a DSN — it's purely describing the
        // seam between V1 (depends on the aggregate) and V2 (depends on
        // IQueryService). Smoke-test that it executes cleanly and shows
        // both options.
        final result = await _runExampleWithoutDsn(
          'example/sub_interfaces_migration_demo.dart',
        );

        expect(result.exitCode, equals(0));
        final out = '${result.stdout}\n${result.stderr}';
        expect(out, contains('IOdbcService'));
        expect(out, contains('IQueryService'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'should_skip_event_bus_demo_when_dsn_is_disabled',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/event_bus_demo.dart',
        );

        expect(result.exitCode, equals(0));
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('Skipping DB-dependent example.'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
