import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_ascii_parse.dart';

/// Wraps a UTF-8 byte slice and decodes it to a [String] only on demand.
///
/// Intended for protocol consumers that hold large result sets where most
/// text cells are never read back as `String` (e.g. only a handful of
/// columns are inspected, the rest are aggregated or piped). Building a
/// `String` for every cell is wasteful in those workloads.
///
/// ## Identity & equality
///
/// [LazyString] equals another [LazyString] **iff their underlying bytes
/// are identical**. It also equals a [String] whose UTF-8 encoding matches
/// — so cells stored as `LazyString` interoperate with comparisons against
/// literal strings (`cell == 'expected'`) the same way as eagerly decoded
/// values would.
///
/// ## Decoding policy
///
/// Uses `utf8.decode(allowMalformed: true)` to mirror the
/// `BinaryProtocolParser._decodeText` contract: invalid bytes become
/// U+FFFD instead of throwing. This keeps the byte stream survivable
/// across malformed driver payloads.
///
/// ## When NOT to use
///
/// - For columns that are always read back: pay the decode once, eager
///   `String` is simpler.
/// - For columns sorted/grouped Dart-side: comparison is byte-wise and
///   may not match locale-aware sort.
///
/// This class is intentionally not produced by the default parser — it is
/// an opt-in primitive that callers can drop into their own decode paths.
///
/// The class carries the `@immutable` marker because its observable identity
/// (equality, hashing, byte length, value) is defined entirely over the
/// final [_bytes] field. The private [_decoded] field is a memoization
/// cache that does not change the value the class represents; we suppress
/// `must_be_immutable` for that reason only.
@immutable
// Reason: private decode cache is intentional memoization; AUDIT-DART-2026-06,
// remove if LazyString is refactored to a non-@immutable holder type.
// ignore: must_be_immutable
class LazyString {
  /// Wraps [bytes] without taking a defensive copy. The caller is
  /// responsible for not mutating the slice after wrapping.
  LazyString(this._bytes);

  final Uint8List _bytes;

  /// Internal memoization cache for the decoded string. Mutating it is
  /// not externally observable; see the class-level docstring for the
  /// immutability rationale.
  String? _decoded;

  /// Number of UTF-8 bytes backing this string. O(1).
  int get byteLength => _bytes.length;

  /// Triggers decoding (or returns the cached result on repeat access).
  String get value {
    final cached = _decoded;
    if (cached != null) {
      return cached;
    }
    if (isAsciiBytes(_bytes)) {
      return _decoded = String.fromCharCodes(_bytes);
    }
    return _decoded = utf8.decode(_bytes, allowMalformed: true);
  }

  /// Whether [value] has been computed yet. Useful in tests and metrics
  /// to confirm the decode actually happens lazily.
  bool get isDecoded => _decoded != null;

  /// Read-only view over the underlying UTF-8 bytes. Mutating the slice
  /// is undefined behaviour and will produce inconsistent results from
  /// [value].
  Uint8List get bytes => _bytes;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is LazyString) {
      if (identical(_bytes, other._bytes)) return true;
      if (_bytes.length != other._bytes.length) return false;
      for (var i = 0; i < _bytes.length; i++) {
        if (_bytes[i] != other._bytes[i]) return false;
      }
      return true;
    }
    if (other is String) {
      // Compare against the eagerly-decoded form so callers writing
      // `cell == 'expected'` continue to work.
      return value == other;
    }
    return false;
  }

  @override
  int get hashCode {
    // Stable hash over the byte sequence. Avoids decoding on hash lookups.
    var h = 0;
    for (var i = 0; i < _bytes.length; i++) {
      h = 0x1fffffff & (h + _bytes[i]);
      h = 0x1fffffff & (h + ((0x0007ffff & h) << 10));
      h ^= h >> 6;
    }
    h = 0x1fffffff & (h + ((0x03ffffff & h) << 3));
    h ^= h >> 11;
    return 0x1fffffff & (h + ((0x00003fff & h) << 15));
  }
}
