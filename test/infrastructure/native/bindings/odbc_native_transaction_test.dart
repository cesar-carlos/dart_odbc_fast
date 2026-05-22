import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/bindings/test_odbc_bindings.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';

void main() {
  group('OdbcNative transactionBegin routing', () {
    test('should_use_v1_entry_point_when_defaults_only', () {
      var v1Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          transactionBegin: (_, __, ___) {
            v1Calls++;
            return 10;
          },
          transactionBeginV2: (_, __, ___, ____) => 20,
          transactionBeginV3: (_, __, ___, ____, _____) => 30,
        ),
      );
      final native = OdbcNative.withBindings(bindings);

      final txnId = native.transactionBegin(1, 2);

      expect(txnId, equals(10));
      expect(v1Calls, equals(1));
    });

    test('should_use_v2_when_access_mode_non_default', () {
      var v2Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          transactionBegin: (_, __, ___) => 10,
          transactionBeginV2: (_, __, ___, accessMode) {
            v2Calls++;
            expect(accessMode, equals(1));
            return 20;
          },
        ),
      );
      final native = OdbcNative.withBindings(bindings);

      final txnId = native.transactionBegin(1, 2, accessMode: 1);

      expect(txnId, equals(20));
      expect(v2Calls, equals(1));
    });

    test('should_use_v3_when_lock_timeout_non_default', () {
      var v3Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          transactionBeginV3: (_, __, ___, ____, lockTimeout) {
            v3Calls++;
            expect(lockTimeout, equals(500));
            return 30;
          },
        ),
      );
      final native = OdbcNative.withBindings(bindings);

      final txnId = native.transactionBegin(
        1,
        2,
        accessMode: 1,
        lockTimeoutMs: 500,
      );

      expect(txnId, equals(30));
      expect(v3Calls, equals(1));
    });

    test('should_expose_transaction_capability_flags_from_bindings', () {
      final v1Only = OdbcNative.withBindings(
        FakeOdbcBindings.transactionV1Only(),
      );

      expect(v1Only.supportsTransactionAccessMode, isFalse);
      expect(v1Only.supportsTransactionLockTimeout, isFalse);
    });

    test('should_use_v3_when_only_lock_timeout_is_non_default', () {
      var v3Calls = 0;
      final bindings = FakeOdbcBindings.custom(
        overrides: TestOdbcBindingsOverrides(
          transactionBegin: (_, __, ___) => 10,
          transactionBeginV2: (_, __, ___, ____) => 20,
          transactionBeginV3: (_, __, ___, ____, lockTimeout) {
            v3Calls++;
            expect(lockTimeout, equals(250));
            return 35;
          },
        ),
      );
      final native = OdbcNative.withBindings(bindings);

      final txnId = native.transactionBegin(1, 2, lockTimeoutMs: 250);

      expect(txnId, equals(35));
      expect(v3Calls, equals(1));
    });
  });
}
