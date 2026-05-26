# Zero-copy FFI for large result buffers — evaluation

## Status

**Future work.** Not implemented in v3.x. This document captures the
viability analysis and the requirements that need to be in place
before implementation is safe.

## Current behavior

Every successful `odbc_exec_query` (and friends) returns a `Uint8List`
to Dart through `lib/infrastructure/native/bindings/ffi_buffer_helper.dart`:

```dart
return Uint8List.fromList(buf.asTypedList(n));
```

The `fromList` call copies the entire `n` bytes from the native scratch
buffer to a fresh Dart-heap `Uint8List`. For result sets in the multi-MB
range this is the single biggest cost on the success path — measured as
**~10-15% of `executeQueryParams` wall-clock time** in microbenchmarks
on a Windows release build.

## Why we copy today

1. **Buffer lifetime**: the FFI scratch buffer (in `ffi_buffer_helper`)
   is reused by the next call. Returning a view would alias the next
   query's output if Dart hadn't finished decoding yet.
2. **GC ownership**: a Dart `Uint8List` produced via
   `pointer.asTypedList(n)` is a *view* — the GC does not free the
   underlying native memory. Mishandling lifetime crashes the host.
3. **API simplicity**: `Uint8List` is the broadly-understood return
   type. Switching to a managed handle adds friction.

## Required changes for zero-copy

### Dart side

- Replace `Uint8List.fromList(buf.asTypedList(n))` with
  `buf.asTypedList(n)` (or a wrapper Finalizable).
- Attach a `NativeFinalizer` whose callback frees the native buffer
  via a Rust-exported `odbc_release_buffer(ptr)`.
- Stop reusing the scratch buffer for the next FFI call. The scratch
  pool either:
  - allocates a fresh buffer per call (regresses allocation cost), or
  - holds a small free-list of buffers to reuse on subsequent calls
    (more complex; requires reference counting).

### Rust side

- New FFI export `odbc_release_buffer(ptr: *mut u8, len: usize)` that
  matches the allocator that produced the buffer (`malloc` / Rust's
  global allocator are not interchangeable on Windows).
- Audit all FFI return paths to ensure they consistently allocate
  through the same allocator as the release function.
- Bump the wire-format ABI version because lifetime semantics of the
  returned pointer change.

### Test suite

- Negative: drop the `Uint8List` view before/after each query and
  assert the next query still works (covers the buffer-reuse race).
- Stress: 10k queries with large result sets, GC forced between calls,
  no leak detected via `cargo tarpaulin --include-tests`.
- Cross-platform: Windows / Linux / macOS allocators behave
  differently; a single-platform test is not enough.

## Risk

- **Use-after-free crashes** if the finalizer fires before the consumer
  has fully drained the buffer. Dart's GC is conservative; finalizers
  run on collection, which is asynchronous.
- **Mismatched allocators on Windows** (CRT vs Rust allocator) cause
  silent heap corruption. Already a known footgun; current copy-based
  code sidesteps it.

## Decision

Defer until:

1. The protocol parser supports streaming consumption from a view
   (`F2.2` `LazyString`-style work landed; needs equivalent for binary
   cells too).
2. The Rust side exposes a stable `odbc_release_buffer` symbol via
   cbindgen.
3. We have benchmark coverage that proves the win is **after** the
   parser already takes its share of the cost — otherwise we shave a
   round-trip of the FFI but spend it on parsing in Dart.

The simpler wins shipped in v3.x — `SqlPointerCache` (F2.1),
`LazyString` (F2.2), `BinaryFrameAccumulator` zero-copy frame
materialization — already remove most of the per-call FFI overhead
without touching wire-format ABI or buffer ownership.

## Tracking

Future implementation should land behind a feature flag
(`zero-copy-result-buffers`) so consumers can opt-in while we collect
production telemetry. The flag stays on Phase 3+ until at least one
release cycle of stability is observed.
