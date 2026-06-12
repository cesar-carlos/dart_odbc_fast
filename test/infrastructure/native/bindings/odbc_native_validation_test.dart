import 'dart:ffi';

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';
import 'test_odbc_bindings.dart';

void main() {
  group('OdbcNative validateConnectionString', () {
    test('should_return_null_when_native_validation_succeeds', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            validateConnectionString: (_, __, ___) => 0,
          ),
        ),
      );

      expect(native.validateConnectionString('DSN=ok'), isNull);
    });

    test('should_decode_error_message_when_validation_fails', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            validateConnectionString:
                FakeOdbcBindings.validateConnectionStringReturns(
              'missing DRIVER',
            ),
          ),
        ),
      );

      expect(
        native.validateConnectionString('bad'),
        equals('missing DRIVER'),
      );
    });

    test('should_return_generic_message_when_error_buffer_is_empty', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            validateConnectionString: (_, errorBuf, len) {
              for (var i = 0; i < len; i++) {
                errorBuf[i] = 0;
              }
              return 1;
            },
          ),
        ),
      );

      expect(
        native.validateConnectionString('bad'),
        equals('Invalid connection string'),
      );
    });
  });

  group('OdbcNative getError', () {
    test('should_return_unknown_error_when_native_returns_negative_length', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            getError: (_, __) => -1,
          ),
        ),
      );

      expect(native.getError(), equals('Unknown error'));
    });

    test('should_return_empty_string_when_native_returns_zero_length', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            getError: (_, __) => 0,
          ),
        ),
      );

      expect(native.getError(), isEmpty);
    });

    test('should_decode_message_when_native_writes_bytes', () {
      final native = OdbcNative.withBindings(
        FakeOdbcBindings.custom(
          overrides: TestOdbcBindingsOverrides(
            getError: FakeOdbcBindings.getErrorWrites('driver timeout'),
          ),
        ),
      );

      expect(native.getError(), equals('driver timeout'));
    });
  });
}
