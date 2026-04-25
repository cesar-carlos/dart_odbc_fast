import 'dart:convert';

import 'package:odbc_fast/infrastructure/native/pool_options.dart';
import 'package:test/test.dart';

void main() {
  group('PoolOptions.toJson', () {
    test('returns null when no options are set', () {
      expect(const PoolOptions().toJson(), isNull);
      expect(const PoolOptions().hasAnyOption, isFalse);
    });

    test('emits the expected JSON shape with single option', () {
      final json =
          const PoolOptions(connectionTimeout: Duration(seconds: 10)).toJson();
      expect(json, isNotNull);
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded, {'connection_timeout_ms': 10000});
    });

    test('emits all three keys when fully set', () {
      final json = const PoolOptions(
        idleTimeout: Duration(minutes: 5),
        maxLifetime: Duration(hours: 1),
        connectionTimeout: Duration(seconds: 30),
      ).toJson();
      final decoded = jsonDecode(json!) as Map<String, dynamic>;
      expect(decoded, {
        'idle_timeout_ms': 5 * 60 * 1000,
        'max_lifetime_ms': 60 * 60 * 1000,
        'connection_timeout_ms': 30 * 1000,
      });
    });

    test('hasAnyOption reflects field state', () {
      expect(
        const PoolOptions(idleTimeout: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
      expect(
        const PoolOptions(maxLifetime: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
      expect(
        const PoolOptions(connectionTimeout: Duration(seconds: 1)).hasAnyOption,
        isTrue,
      );
    });
  });

  group('createPoolDispatch', () {
    test('uses legacy create when options are null or empty', () {
      int legacy(String cs, int max) {
        expect(cs, 'DSN=X');
        expect(max, 4);
        return 7;
      }

      int withOpts(String cs, int max, {String? optionsJson}) {
        fail('with-options path should not run');
      }

      final noOptions = createPoolDispatch(
        supportsPoolCreateWithOptions: true,
        connectionString: 'DSN=X',
        maxSize: 4,
        poolCreate: legacy,
        poolCreateWithOptions: withOpts,
      );
      expect(noOptions, 7);

      const empty = PoolOptions();
      final emptyMap = createPoolDispatch(
        supportsPoolCreateWithOptions: true,
        connectionString: 'DSN=X',
        maxSize: 4,
        options: empty,
        poolCreate: legacy,
        poolCreateWithOptions: withOpts,
      );
      expect(emptyMap, 7);
    });

    test('falls back to legacy when options set but API unsupported', () {
      var legacyCount = 0;
      int legacy(String cs, int max) {
        legacyCount++;
        return 1;
      }

      int withOpts(String cs, int max, {String? optionsJson}) {
        fail('with-options path should not run');
      }

      final id = createPoolDispatch(
        supportsPoolCreateWithOptions: false,
        connectionString: 'DSN=X',
        maxSize: 2,
        options: const PoolOptions(idleTimeout: Duration(seconds: 1)),
        poolCreate: legacy,
        poolCreateWithOptions: withOpts,
      );
      expect(id, 1);
      expect(legacyCount, 1);
    });

    test('uses poolCreateWithOptions when supported and options non-empty', () {
      String? lastJson;
      int legacy(String cs, int max) => fail('legacy should not run');

      int withOpts(String cs, int max, {String? optionsJson}) {
        expect(cs, 'DSN=X');
        expect(max, 3);
        lastJson = optionsJson;
        return 9;
      }

      final id = createPoolDispatch(
        supportsPoolCreateWithOptions: true,
        connectionString: 'DSN=X',
        maxSize: 3,
        options: const PoolOptions(connectionTimeout: Duration(seconds: 10)),
        poolCreate: legacy,
        poolCreateWithOptions: withOpts,
      );
      expect(id, 9);
      expect(
        lastJson,
        '{"connection_timeout_ms":10000}',
        reason: 'JSON matches PoolOptions.toJson for one field',
      );
    });
  });
}
