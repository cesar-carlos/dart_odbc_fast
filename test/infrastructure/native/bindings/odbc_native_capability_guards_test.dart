import 'package:odbc_fast/infrastructure/native/bindings/odbc_native.dart';
import 'package:test/test.dart';

import 'fake_odbc_bindings.dart';

void main() {
  group('OdbcNative async guards', () {
    late OdbcNative native;

    setUp(() {
      native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());
    });

    test('should_return_null_for_execute_async_start_when_api_unsupported', () {
      expect(native.executeAsyncStart(1, 'SELECT 1'), isNull);
    });

    test('should_return_null_for_execute_async_start_params_when_unsupported',
        () {
      expect(native.executeAsyncStartParams(1, 'SELECT 1', null), isNull);
    });

    test('should_return_null_for_async_poll_when_api_unsupported', () {
      expect(native.asyncPoll(1), isNull);
    });

    test('should_return_null_for_async_get_result_when_api_unsupported', () {
      expect(native.asyncGetResult(1), isNull);
    });

    test('should_return_false_for_async_cancel_when_api_unsupported', () {
      expect(native.asyncCancel(1), isFalse);
    });

    test('should_return_false_for_async_free_when_api_unsupported', () {
      expect(native.asyncFree(1), isFalse);
    });
  });

  group('OdbcNative stream guards', () {
    test('should_return_null_for_stream_start_async_when_api_unsupported', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(native.streamStartAsync(1, 'SELECT 1'), isNull);
    });

    test('should_return_null_for_stream_poll_async_when_api_unsupported', () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(native.streamPollAsync(1), isNull);
    });
  });

  group('OdbcNative pool and multi-result guards', () {
    test('should_return_zero_for_pool_create_with_options_when_unsupported',
        () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(
        native.poolCreateWithOptions('DSN=x', 2, optionsJson: '{"k":1}'),
        equals(0),
      );
    });

    test(
        'should_throw_state_error_for_exec_query_multi_params_when_unsupported',
        () {
      final native = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());

      expect(
        () => native.execQueryMultiParams(1, 'SELECT 1', null),
        throwsA(isA<StateError>()),
      );
    });

    test('should_forward_supports_flags_from_injected_bindings', () {
      final legacy = OdbcNative.withBindings(FakeOdbcBindings.legacyMinimal());
      final asyncOnly = OdbcNative.withBindings(FakeOdbcBindings.asyncOnly());

      expect(legacy.supportsAsyncExecuteApi, isFalse);
      expect(legacy.supportsAuditApi, isFalse);
      expect(asyncOnly.supportsAsyncExecuteApi, isTrue);
      expect(asyncOnly.supportsAsyncExecuteParamsApi, isFalse);
    });
  });
}
