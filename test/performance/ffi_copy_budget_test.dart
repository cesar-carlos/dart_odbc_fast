/// Copy-budget regression for the Dart FFI buffer helper.
///
/// Runs DSN-free with fake callbacks. Asserts allocation and copy counts per
/// payload size, not wall-clock. Tagged `perf` so CI can keep it on the
/// performance lane. When `BENCH_BASELINE_OUT` is set the test also writes a
/// JSON snapshot for `tool/compare_benchmark_baseline.dart`.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/bindings/ffi_buffer_helper.dart';
import 'package:odbc_fast/infrastructure/native/bindings/ffi_copy_budget.dart';
import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:test/test.dart';

Uint8List? _fill(int n, int initialSize) => callWithBuffer(
      (buf, bufLen, outWritten) {
        if (bufLen < n) {
          outWritten.value = n;
          return -2;
        }
        buf.asTypedList(n).fillRange(0, n, 7);
        outWritten.value = n;
        return 0;
      },
      initialSize: initialSize,
      maxSize: 2 * 1024 * 1024,
    );

void main() {
  setUp(resetZeroCopyResultBufferBindingForTest);

  group('callWithBuffer copy budget', () {
    test(
      'should_reuse_transient_pool_for_payloads_below_zero_copy_threshold',
      () {
        const n = 16 * 1024;
        const seed = 64 * 1024;
        final first = _fill(n, seed);
        expect(first, hasLength(n));
        final afterFirst = ffiCopyBudgetSnapshot();
        expect(afterFirst.resultMallocs, 1);
        expect(afterFirst.resultCopiedBytes, n);
        expect(afterFirst.zeroCopyViews, 0);

        resetFfiCopyBudgetForTest();
        final second = _fill(n, seed);
        expect(second, hasLength(n));
        final afterSecond = ffiCopyBudgetSnapshot();
        expect(afterSecond.resultMallocs, 0);
        expect(afterSecond.resultCopiedBytes, n);
        expect(afterSecond.zeroCopyViews, 0);
      },
      tags: ['perf'],
    );

    test(
      'should_return_zero_copy_view_from_32kib_through_seed',
      () {
        for (final n in [32 * 1024, 64 * 1024, 256 * 1024]) {
          resetZeroCopyResultBufferBindingForTest();
          final result = _fill(n, n);
          expect(result, hasLength(n));
          final snap = ffiCopyBudgetSnapshot();
          expect(
            snap.resultCopiedBytes,
            0,
            reason: '$n bytes should not fromList',
          );
          expect(snap.zeroCopyViews, 1, reason: '$n bytes should be a view');
          expect(snap.resultMallocs, 1);
        }
      },
      tags: ['perf'],
    );

    test(
      'should_copy_once_when_scratch_seed_cannot_detach_large_result',
      () {
        const n = zeroCopyResultThresholdBytes;
        final result = callWithBuffer(
          (buf, bufLen, outWritten) {
            if (bufLen < n) {
              outWritten.value = n;
              return -2;
            }
            buf.asTypedList(n).fillRange(0, n, 4);
            outWritten.value = n;
            return 0;
          },
          initialSize: 16 * 1024,
          maxSize: n,
        );
        expect(result, hasLength(n));
        final snap = ffiCopyBudgetSnapshot();
        expect(snap.resultScratchCopiedBytes, 0);
        expect(snap.resultCopiedBytes, 0);
        expect(snap.zeroCopyViews, 1);
      },
      tags: ['perf'],
    );

    test(
      'should_resize_once_for_one_mebibyte_without_scratch_copy',
      () {
        const n = 1024 * 1024;
        final result = _fill(n, 256 * 1024);
        expect(result, hasLength(n));
        final snap = ffiCopyBudgetSnapshot();
        expect(snap.resultCopiedBytes, 0);
        expect(snap.zeroCopyViews, 1);
        expect(snap.resultMallocs, 2);
      },
      tags: ['perf'],
    );

    test(
      'should_adopt_native_payload_across_isolate_message_without_fromList',
      () {
        const n = zeroCopyResultThresholdBytes;
        final bytes = _fill(n, n)!;
        resetFfiCopyBudgetForTest();
        final response = isolateQueryDataResponse(1, bytes);
        expect(response.hasData, isTrue);
        expect(response.data, hasLength(n));
        final snap = ffiCopyBudgetSnapshot();
        expect(snap.isolateTransferCopiedBytes, 0);
        expect(snap.isolateAdoptedBytes, n);
      },
      tags: ['perf'],
    );
  });

  test(
    'should_emit_optional_baseline_json_when_BENCH_BASELINE_OUT_is_set',
    () {
      const n = 16 * 1024;
      _fill(n, 64 * 1024);
      final snap = ffiCopyBudgetSnapshot();
      final baselineOut = Platform.environment['BENCH_BASELINE_OUT'];
      if (baselineOut == null || baselineOut.isEmpty) {
        return;
      }
      final payload = [
        <String, Object?>{
          'scenario': 'ffi_copy_budget.small_payload',
          'elapsedMs': 0,
          'rowsPerSecond': 0,
          'queriesPerSecond': 0,
          'latencyP95Micros': 0,
          'fallbacksToBlocking': 0,
          'resultMallocs': snap.resultMallocs,
          'resultCopiedBytes': snap.resultCopiedBytes,
        },
      ];
      final file = File(baselineOut);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    },
    tags: ['perf'],
  );
}
