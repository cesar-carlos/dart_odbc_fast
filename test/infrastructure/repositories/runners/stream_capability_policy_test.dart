/// Unit tests for [StreamCapabilityPolicy].
library;

import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/odbc_backend.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_capability_policy.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';
import '../../native/bindings/fake_odbc_bindings.dart';

NativeOdbcConnection _stubSyncConnection({
  required bool supportsMultiResultStream,
}) {
  return NativeOdbcConnection.testing(
    OdbcNative.withBindings(
      FakeOdbcBindings.stub(
        handlers: StubOdbcBindingsHandlers(
          forceSupportsMultiResultStream: supportsMultiResultStream,
        ),
      ),
    ),
  );
}

void main() {
  group('StreamCapabilityPolicy', () {
    test('should_enable_stream_query_multi_when_async_backend', () {
      final native = FakeAsyncNativeForRepositoryErrors();
      addTearDown(native.dispose);
      final policy = StreamCapabilityPolicy(
        OdbcFfiDispatch(AsyncBackend(native)),
      );

      expect(policy.supportsStreamQueryMulti, isTrue);
    });

    test(
      'should_enable_stream_query_multi_when_sync_backend_exports_multi_stream',
      () {
        final sync = _stubSyncConnection(supportsMultiResultStream: true);
        final policy = StreamCapabilityPolicy(
          OdbcFfiDispatch(SyncBackend(sync)),
        );

        expect(policy.supportsStreamQueryMulti, isTrue);
      },
    );

    test(
      'should_disable_stream_query_multi_when_sync_backend_lacks_multi_stream',
      () {
        final sync = _stubSyncConnection(supportsMultiResultStream: false);
        final policy = StreamCapabilityPolicy(
          OdbcFfiDispatch(SyncBackend(sync)),
        );

        expect(policy.supportsStreamQueryMulti, isFalse);
      },
    );
  });
}
