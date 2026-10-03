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
    const liveExamples = [
      'quick_start_balanced_demo.dart',
      'recommended_performance_patterns_demo.dart',
      'named_parameters_demo.dart',
      'query_result_access_demo.dart',
      'streaming_demo.dart',
      'typed_columnar_demo.dart',
      'stream_query_columnar_demo.dart',
      'multi_result_demo.dart',
      'multi_result_batches_demo.dart',
      'bulk_insert_demo.dart',
      'bulk_insert_parallel_demo.dart',
      'high_concurrency_pool_demo.dart',
      'run_in_transaction_demo.dart',
      'savepoint_demo.dart',
      'xa_2pc_demo.dart',
      'execute_async_demo.dart',
      'backpressure_modes_demo.dart',
      'stream_query_named_demo.dart',
      'event_bus_demo.dart',
      'async_concurrency_benchmark.dart',
      'streaming_performance_benchmark.dart',
      'multi_result_performance_benchmark.dart',
    ];
    for (final example in liveExamples) {
      test(
        'should_skip_${example}_when_dsn_is_disabled',
        () async {
          final result = await _runExampleWithoutDsn('example/$example');
          expect(result.exitCode, 0);
          expect(
            '${result.stdout}\n${result.stderr}',
            contains('Skipping DB-dependent example.'),
          );
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }

    test(
      'should_skip_oracle_ref_cursor_without_explicit_call',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/oracle_ref_cursor_demo.dart',
        );
        expect(result.exitCode, 0);
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('ODBC_ORACLE_REFCURSOR_CALL not set'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'should_run_telemetry_decorators_without_dsn',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/telemetry_decorators_demo.dart',
        );
        expect(result.exitCode, 0);
        expect(
          '${result.stdout}\n${result.stderr}',
          contains('ODBC.initialize'),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'should_run_native_assets_resolution_without_dsn',
      () async {
        final result = await _runExampleWithoutDsn(
          'example/native_assets_resolution_demo.dart',
        );
        expect(result.exitCode, 0);
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, contains('Native library resolution'));
        expect(output, contains('ODBC_FAST_PREFER_LOCAL_BUILD'));
        expect(output, contains('ODBC_FAST_SKIP_DOWNLOAD'));
        expect(output, contains('Preferred on-disk path'));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
