/// Unit tests for [OdbcBackend] sealed hierarchy.
library;

import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcBackend', () {
    test('should_wrap_NativeOdbcConnection_as_SyncBackend', () {
      final native = NativeOdbcConnection();
      addTearDown(native.dispose);

      final backend = OdbcBackend.fromNative(native);

      expect(backend, isA<SyncBackend>());
      expect(backend.isAsync, isFalse);
      expect((backend as SyncBackend).connection, same(native));
    });

    test('should_wrap_AsyncNativeOdbcConnection_as_AsyncBackend', () {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: Duration.zero,
      );
      addTearDown(async.dispose);

      final backend = OdbcBackend.fromNative(async);

      expect(backend, isA<AsyncBackend>());
      expect(backend.isAsync, isTrue);
      expect((backend as AsyncBackend).connection, same(async));
    });

    test('should_throw_ArgumentError_for_unsupported_native_type', () {
      expect(
        () => OdbcBackend.fromNative(Object()),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('NativeOdbcConnection or AsyncNativeOdbcConnection'),
          ),
        ),
      );
    });

    test('should_dispatch_via_exhaustive_switch_pattern_match', () {
      final native = NativeOdbcConnection();
      addTearDown(native.dispose);
      final async = AsyncNativeOdbcConnection(
        requestTimeout: Duration.zero,
      );
      addTearDown(async.dispose);

      String describe(OdbcBackend backend) => switch (backend) {
            SyncBackend(:final connection) => 'sync:${connection.runtimeType}',
            AsyncBackend(:final connection) =>
              'async:${connection.runtimeType}',
          };

      expect(
        describe(SyncBackend(native)),
        equals('sync:NativeOdbcConnection'),
      );
      expect(
        describe(AsyncBackend(async)),
        equals('async:AsyncNativeOdbcConnection'),
      );
    });
  });

  group('SyncBackend', () {
    test('should_expose_underlying_NativeOdbcConnection', () {
      final native = NativeOdbcConnection();
      addTearDown(native.dispose);

      final wrapped = SyncBackend(native);

      expect(wrapped.connection, same(native));
      expect(wrapped.isAsync, isFalse);
    });
  });

  group('AsyncBackend', () {
    test('should_expose_underlying_AsyncNativeOdbcConnection', () {
      final async = AsyncNativeOdbcConnection(
        requestTimeout: Duration.zero,
      );
      addTearDown(async.dispose);

      final wrapped = AsyncBackend(async);

      expect(wrapped.connection, same(async));
      expect(wrapped.isAsync, isTrue);
    });
  });
}
