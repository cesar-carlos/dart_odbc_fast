/// Unit tests for [SqlPointerCache].
library;

import 'dart:ffi' as ffi;

import 'package:odbc_fast/infrastructure/native/bindings/odbc_bindings.dart'
    as bindings;
import 'package:odbc_fast/infrastructure/native/bindings/sql_pointer_cache.dart';
import 'package:test/test.dart';

ffi.Pointer<bindings.Utf8> _ptr<T extends bindings.Utf8>(
  ffi.Pointer<T> p,
) =>
    p as ffi.Pointer<bindings.Utf8>;

void main() {
  group('SqlPointerCache', () {
    late SqlPointerCache cache;

    setUp(() {
      cache = SqlPointerCache(maxSize: 4);
    });

    tearDown(() {
      cache.dispose();
    });

    test('should_allocate_pointer_on_first_acquire_and_count_miss', () {
      final ptr = cache.acquire('SELECT 1');

      expect(ptr.address, isNot(0));
      expect(cache.length, 1);
      expect(cache.containsSql('SELECT 1'), isTrue);
      expect(cache.stats.hits, 0);
      expect(cache.stats.misses, 1);
    });

    test('should_return_same_pointer_on_repeated_acquire_and_count_hit', () {
      final first = cache.acquire('SELECT 1');
      final second = cache.acquire('SELECT 1');
      final third = cache.acquire('SELECT 1');

      expect(_ptr(second).address, equals(_ptr(first).address));
      expect(_ptr(third).address, equals(_ptr(first).address));
      expect(cache.length, 1);
      expect(cache.stats.hits, 2);
      expect(cache.stats.misses, 1);
    });

    test('should_treat_distinct_SQL_as_separate_entries', () {
      final a = cache.acquire('SELECT 1');
      final b = cache.acquire('SELECT 2');

      expect(_ptr(a).address, isNot(equals(_ptr(b).address)));
      expect(cache.length, 2);
      expect(cache.stats.misses, 2);
    });

    test('should_evict_oldest_entry_when_maxSize_exceeded', () {
      cache
        ..acquire('SELECT 1')
        ..acquire('SELECT 2')
        ..acquire('SELECT 3')
        ..acquire('SELECT 4');
      expect(cache.length, 4);

      // Inserting the 5th forces eviction of the oldest ('SELECT 1').
      cache.acquire('SELECT 5');
      expect(cache.length, 4);
      expect(cache.containsSql('SELECT 1'), isFalse);
      expect(cache.containsSql('SELECT 5'), isTrue);
      expect(cache.stats.evictions, 1);
    });

    test('should_refresh_LRU_position_on_hit', () {
      cache
        ..acquire('SELECT 1') // oldest
        ..acquire('SELECT 2')
        ..acquire('SELECT 3')
        ..acquire('SELECT 4')
        // Touch the oldest so it is no longer LRU.
        ..acquire('SELECT 1')
        // Insert a 5th — evicts what is now the oldest ('SELECT 2').
        ..acquire('SELECT 5');

      expect(cache.containsSql('SELECT 1'), isTrue);
      expect(cache.containsSql('SELECT 2'), isFalse);
    });

    test('should_release_all_pointers_on_dispose', () {
      cache
        ..acquire('SELECT 1')
        ..acquire('SELECT 2');
      expect(cache.length, 2);

      cache.dispose();
      expect(cache.length, 0);
    });

    test('resetStats clears counters but keeps cached entries', () {
      cache
        ..acquire('SELECT 1')
        ..acquire('SELECT 1');
      expect(cache.stats.hits, 1);

      cache.resetStats();
      expect(cache.stats.hits, 0);
      expect(cache.stats.misses, 0);
      expect(cache.length, 1);
    });
  });
}
