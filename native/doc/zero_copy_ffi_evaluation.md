# Zero-copy FFI for large result buffers

## Status

**Shipped (v4.1+; compatibility expanded in v4.5.1).** Successful FFI payloads
at or above 32 KiB can return a zero-copy `Uint8List` view backed by a
Dart-allocated native buffer. A Dart `NativeFinalizer(malloc.nativeFree)`
releases that buffer. Smaller payloads still use `Uint8List.fromList` (copy)
because the copy cost is small relative to finalizer overhead.

Implementation lives in:

- Dart: `lib/infrastructure/native/bindings/ffi_buffer_helper.dart`
  (`zeroCopyResultThresholdBytes`, `isZeroCopyResultBufferAvailable`)
- Rust: `odbc_release_buffer` remains an ABI 1.1 export for C consumers, but
  Dart does not require it for this path

## Current behavior

`callWithBuffer` / stream helpers:

1. Prefer a **transient** malloc for large params/results when asked
   (`preferTransient`), so large payloads are not forced through the reusable
   scratch pool (scratch reuse would require an extra scratch→owned copy before
   attaching a finalizer).
2. On success with `n >= 32 KiB`: return a view over the Dart-owned transient
   buffer and attach `NativeFinalizer(malloc.nativeFree)`. The finalizer owner
   is retained alongside the view and inherited by internal slices.
3. Otherwise: `Uint8List.fromList` copy, then free the native buffer immediately.

## Historical notes (pre-zero-copy)

Before v4.1 every successful path copied via `Uint8List.fromList`. That copy
was measured at roughly **10-15%** of `executeQueryParams` wall time for
multi-MB results on Windows release builds. The evaluation below motivated the
shipped design.

## Why small payloads still copy

1. **Finalizer overhead** dominates for tiny frames.
2. **Scratch pool reuse** remains useful for small sync calls; returning a view
   into a reused scratch buffer is unsafe.
3. API consumers continue to receive a plain `Uint8List`.

## Risks (still apply)

- **Lifetime coupling**: the returned `Uint8List` retains its finalizer owner;
  callers may retain the view normally, but internal code must preserve backing
  provenance when creating native-backed slices.
- **Allocator pairing**: Dart `package:ffi` `malloc` / `nativeFree` must match
  the allocator used for the owned buffer on the success path.

## Scope

This ownership model applies only to buffers allocated by Dart with
`package:ffi` `malloc`. It does not replace the release contract for buffers
returned by native APIs such as columnar decompression.
