/// Internal copy/allocation counters for FFI hot-path regression tests.
///
/// Not exported from the public barrel. Tests reset via
/// [resetFfiCopyBudgetForTest] and read [ffiCopyBudgetSnapshot].
library;

/// Snapshot of FFI copy and allocation counters since the last reset.
class FfiCopyBudgetSnapshot {
  const FfiCopyBudgetSnapshot({
    required this.resultMallocs,
    required this.resultCopiedBytes,
    required this.resultScratchCopiedBytes,
    required this.zeroCopyViews,
    required this.paramCopiedBytes,
    required this.isolateTransferCopiedBytes,
    required this.isolateAdoptedBytes,
  });

  /// Native result buffers obtained from `malloc` (pool misses).
  final int resultMallocs;

  /// Bytes copied with `Uint8List.fromList` when materializing FFI results.
  final int resultCopiedBytes;

  /// Bytes copied from a reusable scratch slot into an owned buffer.
  final int resultScratchCopiedBytes;

  /// Successful zero-copy views attached to a native finalizer.
  final int zeroCopyViews;

  /// Bytes copied when staging parameter payloads for FFI.
  final int paramCopiedBytes;

  /// Bytes copied through `TransferableTypedData.fromList` across isolates.
  final int isolateTransferCopiedBytes;

  /// Bytes transferred by adopting a Dart-owned malloc between isolates.
  final int isolateAdoptedBytes;
}

int _resultMallocs = 0;
int _resultCopiedBytes = 0;
int _resultScratchCopiedBytes = 0;
int _zeroCopyViews = 0;
int _paramCopiedBytes = 0;
int _isolateTransferCopiedBytes = 0;
int _isolateAdoptedBytes = 0;

/// Records one native result `malloc`.
void recordFfiResultMalloc() {
  _resultMallocs++;
}

/// Records a heap copy of [byteCount] result bytes.
void recordFfiResultCopy(int byteCount) {
  _resultCopiedBytes += byteCount;
}

/// Records a scratch-to-owned copy of [byteCount] result bytes.
void recordFfiResultScratchCopy(int byteCount) {
  _resultScratchCopiedBytes += byteCount;
}

/// Records one zero-copy result view.
void recordFfiZeroCopyView() {
  _zeroCopyViews++;
}

/// Records [byteCount] copied into a parameter scratch or transient buffer.
void recordFfiParamCopy(int byteCount) {
  _paramCopiedBytes += byteCount;
}

/// Records [byteCount] copied for isolate transferable typed data.
void recordFfiIsolateTransferCopy(int byteCount) {
  _isolateTransferCopiedBytes += byteCount;
}

/// Records [byteCount] adopted across isolates without copying.
void recordFfiIsolateAdopt(int byteCount) {
  _isolateAdoptedBytes += byteCount;
}

/// Current counters since the last [resetFfiCopyBudgetForTest].
FfiCopyBudgetSnapshot ffiCopyBudgetSnapshot() => FfiCopyBudgetSnapshot(
      resultMallocs: _resultMallocs,
      resultCopiedBytes: _resultCopiedBytes,
      resultScratchCopiedBytes: _resultScratchCopiedBytes,
      zeroCopyViews: _zeroCopyViews,
      paramCopiedBytes: _paramCopiedBytes,
      isolateTransferCopiedBytes: _isolateTransferCopiedBytes,
      isolateAdoptedBytes: _isolateAdoptedBytes,
    );

/// Clears counters. Tests must call this in `setUp`.
void resetFfiCopyBudgetForTest() {
  _resultMallocs = 0;
  _resultCopiedBytes = 0;
  _resultScratchCopiedBytes = 0;
  _zeroCopyViews = 0;
  _paramCopiedBytes = 0;
  _isolateTransferCopiedBytes = 0;
  _isolateAdoptedBytes = 0;
}
