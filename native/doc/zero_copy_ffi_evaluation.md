# Zero-copy FFI for large result buffers

## Status

**Shipped (v4.1+).** Successful FFI payloads at or above 32 KiB can return a
zero-copy `Uint8List` view backed by a native buffer, with release via
`odbc_release_buffer` and a Dart `NativeFinalizer`. Smaller payloads still use
`Uint8List.fromList` (copy) because the copy cost is small relative to
finalizer overhead.

Implementation lives in:

- Dart: `lib/infrastructure/native/bindings/ffi_buffer_helper.dart`
  (`zeroCopyResultThresholdBytes`, `isZeroCopyResultBufferAvailable`)
- Rust: `odbc_release_buffer` export

## Current behavior

`callWithBuffer` / stream helpers:

1. Prefer a **transient** malloc for large params/results when asked
   (`preferTransient`), so large payloads are not forced through the reusable
   scratch pool (scratch reuse would require an extra scratch→owned copy before
   attaching a finalizer).
2. On success with `n >= 32 KiB` and `odbc_release_buffer` available: return a
   view over the owned native buffer and attach `NativeFinalizer(malloc.nativeFree)`.
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

- **Use-after-free** if a consumer retains a zero-copy view incorrectly across
  native free (mitigated by keeping the `Finalizable` token alive with the
  list).
- **Allocator pairing**: Dart `package:ffi` `malloc` / `nativeFree` must match
  the allocator used for the owned buffer on the success path.

## Follow-ups

- Prefer transient allocation more aggressively for large results even when the
  caller did not pass large params (see performance plan hot-path work).
- Document consumer guidance: decode promptly; do not stash zero-copy views
  across long async gaps without retaining the owning object.
