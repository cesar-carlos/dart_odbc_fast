/// Unit tests for [LazyString].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:test/test.dart';

void main() {
  group('LazyString', () {
    test('should_not_decode_until_value_is_accessed', () {
      final lazy = LazyString(Uint8List.fromList(utf8.encode('hello')));

      expect(lazy.isDecoded, isFalse);
      expect(lazy.byteLength, equals(5));
    });

    test('should_decode_lazily_on_first_value_access_and_cache', () {
      final lazy = LazyString(Uint8List.fromList(utf8.encode('caf\u00e9')));

      expect(lazy.isDecoded, isFalse);
      final first = lazy.value;
      expect(first, equals('caf\u00e9'));
      expect(lazy.isDecoded, isTrue);

      // Subsequent reads hit the cached value (identity check).
      expect(identical(lazy.value, first), isTrue);
    });

    test('should_replace_invalid_utf8_with_U+FFFD_replacement_char', () {
      // Truncated 2-byte UTF-8 sequence: lead byte without continuation.
      final invalid = Uint8List.fromList([0xC3]);
      final lazy = LazyString(invalid);
      expect(lazy.value, contains('\uFFFD'));
    });

    test('should_compare_byte_equal_LazyStrings_as_equal', () {
      final a = LazyString(Uint8List.fromList(utf8.encode('foo')));
      final b = LazyString(Uint8List.fromList(utf8.encode('foo')));

      expect(a == b, isTrue);
      expect(a.hashCode, equals(b.hashCode));
    });

    test('should_compare_LazyString_to_String_via_decoded_value', () {
      final lazy = LazyString(Uint8List.fromList(utf8.encode('hello')));

      // LazyString.== accepts a String to allow drop-in comparison against
      // literal expected values; the analyzer cannot infer that from the
      // generic Object signature, hence the targeted suppression.
      // ignore: unrelated_type_equality_checks
      expect(lazy == 'hello', isTrue);
      // Same rationale as above: comparing LazyString to a literal String is
      // an intentional part of the public equality contract.
      // ignore: unrelated_type_equality_checks
      expect(lazy == 'world', isFalse);
    });

    test('should_treat_different_byte_payloads_as_unequal', () {
      final a = LazyString(Uint8List.fromList(utf8.encode('foo')));
      final b = LazyString(Uint8List.fromList(utf8.encode('bar')));

      expect(a == b, isFalse);
    });

    test('should_provide_stable_hashCode_independent_of_decode_state', () {
      final a = LazyString(Uint8List.fromList(utf8.encode('hello')));
      final hashBeforeDecode = a.hashCode;
      a.value;
      expect(a.hashCode, equals(hashBeforeDecode));
    });

    test('toString_returns_decoded_value', () {
      final lazy = LazyString(Uint8List.fromList(utf8.encode('hi')));
      expect('$lazy', equals('hi'));
    });

    test('bytes_getter_exposes_underlying_slice', () {
      final source = Uint8List.fromList([0x68, 0x69]);
      final lazy = LazyString(source);
      expect(lazy.bytes, same(source));
    });
  });
}
