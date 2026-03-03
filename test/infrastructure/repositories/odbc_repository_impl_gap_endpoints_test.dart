import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

class _FakeAsyncNativeForGapErrors extends AsyncNativeOdbcConnection {
  _FakeAsyncNativeForGapErrors() : super(requestTimeout: Duration.zero);

  String errorMessage = 'native error';

  @override
  Future<bool> initialize() async => true;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async => 42;

  @override
  Future<bool> disconnect(int connectionId) async => true;

  @override
  Future<String> getError() async => errorMessage;

  @override
  Future<StructuredError?> getStructuredError() async => null;

  @override
  Future<String?> getDriverCapabilitiesJson(String connectionString) async =>
      '{invalid_json';

  @override
  Future<String?> getAuditStatusJson() async => '[]';

  @override
  Future<String?> getAuditEventsJson({int limit = 0}) async => '{}';

  @override
  Future<String?> getMetadataCacheStatsJson() async => '{bad_json';

  @override
  Future<String?> poolGetStateJson(int poolId) async => '{bad_json';

  @override
  Future<int> executeAsyncStart(int connectionId, String sql) async => 0;

  @override
  Future<int> streamStartAsync(
    int connectionId,
    String sql, {
    int fetchSize = 1000,
    int chunkSize = 64 * 1024,
  }) async =>
      0;

  @override
  void dispose() {}
}

void main() {
  group('OdbcRepositoryImpl new endpoint error paths', () {
    late _FakeAsyncNativeForGapErrors asyncNative;
    late OdbcRepositoryImpl repository;
    late String connectionId;

    setUp(() async {
      asyncNative = _FakeAsyncNativeForGapErrors();
      repository = OdbcRepositoryImpl(asyncNative);
      await repository.initialize();
      final connResult = await repository.connect('DSN=Fake');
      final connection = connResult.getOrNull();
      expect(connection, isNotNull);
      connectionId = connection!.id;
    });

    test('getDriverCapabilities returns QueryError for invalid JSON', () async {
      final result = await repository.getDriverCapabilities('DSN=Fake');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('getAuditStatus returns QueryError for invalid payload format',
        () async {
      final result = await repository.getAuditStatus();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect(
            (e as QueryError).message,
            contains('Invalid audit status payload format'),
          );
        },
      );
    });

    test('getAuditEvents returns QueryError for invalid payload format',
        () async {
      final result = await repository.getAuditEvents();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect(
            (e as QueryError).message,
            contains('Invalid audit events payload format'),
          );
        },
      );
    });

    test('metadataCacheStats returns QueryError for invalid JSON', () async {
      final result = await repository.metadataCacheStats();
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('poolGetStateDetailed returns QueryError for invalid JSON', () async {
      final result = await repository.poolGetStateDetailed(1);
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) {
          expect(e, isA<QueryError>());
          expect((e as QueryError).message, contains('Invalid'));
        },
      );
    });

    test('executeAsyncStart returns failure when native returns zero',
        () async {
      final result =
          await repository.executeAsyncStart(connectionId, 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<UnsupportedFeatureError>()),
      );
    });

    test('streamStartAsync returns failure when native returns zero', () async {
      final result =
          await repository.streamStartAsync(connectionId, 'SELECT 1');
      expect(result.isSuccess(), isFalse);
      result.fold(
        (_) => fail('Expected failure'),
        (e) => expect(e, isA<UnsupportedFeatureError>()),
      );
    });
  });
}
