/// Focused test suite for new public endpoints exposed from Rust to Dart.
///
/// Covers: getVersion, validateConnectionString, getDriverCapabilities,
/// Audit API, poolGetStateDetailed, metadata cache, cancelStream,
/// async query lifecycle, async stream lifecycle.
library;

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/directed_param.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

void main() {
  group('New public endpoints (service layer)', () {
    late MockOdbcRepository mockRepo;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    group('getVersion', () {
      test('returns version map and delegates to repository', () async {
        await service.initialize();
        final result = await service.getVersion();
        expect(result.isSuccess(), isTrue);
        final version = result.getOrNull()!;
        expect(version, containsPair('api', '0.1.0'));
        expect(version, containsPair('abi', '1.0.0'));
        expect(mockRepo.getVersionCalled, isTrue);
      });
    });

    group('validateConnectionString', () {
      test('succeeds for valid connection string', () async {
        await service.initialize();
        final result =
            await service.validateConnectionString('DSN=MyDb;UID=u;PWD=p');
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.validateConnectionStringCalled, isTrue);
      });

      test('fails for empty connection string', () async {
        await service.initialize();
        final result = await service.validateConnectionString('');
        expect(result.isSuccess(), isFalse);
        result.fold(
          (_) => fail('Expected failure'),
          (e) {
            expect(e, isA<ValidationError>());
            expect((e as ValidationError).message, contains('empty'));
          },
        );
      });
    });

    group('getDriverCapabilities', () {
      test('returns capabilities map and delegates to repository', () async {
        await service.initialize();
        final result = await service.getDriverCapabilities('DSN=MyDb');
        expect(result.isSuccess(), isTrue);
        final caps = result.getOrNull()!;
        expect(caps['driver_name'], equals('mock'));
        expect(caps['supports_streaming'], equals(true));
        expect(mockRepo.getDriverCapabilitiesCalled, isTrue);
      });
    });

    group('Audit API', () {
      test('setAuditEnabled delegates to repository', () async {
        await service.initialize();
        final result = await service.setAuditEnabled(enabled: true);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.setAuditEnabledCalled, isTrue);
      });

      test('getAuditStatus returns status map', () async {
        await service.initialize();
        final result = await service.getAuditStatus();
        expect(result.isSuccess(), isTrue);
        final status = result.getOrNull()!;
        expect(status['enabled'], equals(true));
        expect(mockRepo.getAuditStatusCalled, isTrue);
      });

      test('getAuditEvents returns event list', () async {
        await service.initialize();
        final result = await service.getAuditEvents(limit: 10);
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull(), isEmpty);
        expect(mockRepo.getAuditEventsCalled, isTrue);
      });

      test('clearAuditEvents delegates to repository', () async {
        await service.initialize();
        final result = await service.clearAuditEvents();
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.clearAuditEventsCalled, isTrue);
      });
    });

    group('poolGetStateDetailed', () {
      test('returns detailed pool state map', () async {
        await service.initialize();
        final result = await service.poolGetStateDetailed(1);
        expect(result.isSuccess(), isTrue);
        final state = result.getOrNull()!;
        expect(state['total_connections'], equals(1));
        expect(state['max_size'], equals(4));
        expect(mockRepo.poolGetStateDetailedCalled, isTrue);
      });
    });

    group('Metadata cache', () {
      test('metadataCacheEnable delegates to repository', () async {
        await service.initialize();
        final result = await service.metadataCacheEnable(
          maxEntries: 100,
          ttlSeconds: 60,
        );
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.metadataCacheEnableCalled, isTrue);
      });

      test('metadataCacheStats returns stats map', () async {
        await service.initialize();
        final result = await service.metadataCacheStats();
        expect(result.isSuccess(), isTrue);
        final stats = result.getOrNull()!;
        expect(stats, contains('hits'));
        expect(stats, contains('misses'));
        expect(mockRepo.metadataCacheStatsCalled, isTrue);
      });

      test('clearMetadataCache delegates to repository', () async {
        await service.initialize();
        final result = await service.clearMetadataCache();
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.clearMetadataCacheCalled, isTrue);
      });
    });

    group('cancelStream', () {
      test('delegates to repository', () async {
        await service.initialize();
        final result = await service.cancelStream(1);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.cancelStreamCalled, isTrue);
      });
    });

    group('Async query lifecycle', () {
      late String connectionId;

      setUp(() async {
        await service.initialize();
        final connResult = await service.connect('DSN=test');
        connectionId = connResult.getOrNull()!.id;
      });

      test('executeAsyncStart returns request ID', () async {
        final result =
            await service.executeAsyncStart(connectionId, 'SELECT 1');
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull(), equals(1));
        expect(mockRepo.executeAsyncStartCalled, isTrue);
      });

      test('asyncPoll returns status', () async {
        await service.executeAsyncStart(connectionId, 'SELECT 1');
        final result = await service.asyncPoll(1);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.asyncPollCalled, isTrue);
      });

      test('asyncGetResult returns query result', () async {
        await service.executeAsyncStart(connectionId, 'SELECT 1');
        final result = await service.asyncGetResult(1);
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull()!.rowCount, equals(1));
        expect(mockRepo.asyncGetResultCalled, isTrue);
      });

      test('asyncCancel delegates to repository', () async {
        await service.executeAsyncStart(connectionId, 'SELECT 1');
        final result = await service.asyncCancel(1);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.asyncCancelCalled, isTrue);
      });

      test('asyncFree delegates to repository', () async {
        await service.executeAsyncStart(connectionId, 'SELECT 1');
        final result = await service.asyncFree(1);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.asyncFreeCalled, isTrue);
      });
    });

    test('executeQueryDirectedParams uses executeQueryParamBuffer', () async {
      await service.initialize();
      final cr = await service.connect('DSN=test');
      final id = cr.getOrThrow().id;
      final r = await service.executeQueryDirectedParams(
        id,
        'SELECT 1',
        const [DirectedParam(value: 1)],
      );
      expect(r.isSuccess(), isTrue);
      expect(mockRepo.executeQueryParamBufferCalled, isTrue);
    });

    group('Async stream lifecycle', () {
      late String connectionId;

      setUp(() async {
        await service.initialize();
        final connResult = await service.connect('DSN=test');
        connectionId = connResult.getOrNull()!.id;
      });

      test('streamStartAsync returns stream ID', () async {
        final result = await service.streamStartAsync(connectionId, 'SELECT 1');
        expect(result.isSuccess(), isTrue);
        expect(result.getOrNull(), equals(1));
        expect(mockRepo.streamStartAsyncCalled, isTrue);
      });

      test('streamPollAsync delegates to repository', () async {
        await service.streamStartAsync(connectionId, 'SELECT 1');
        final result = await service.streamPollAsync(1);
        expect(result.isSuccess(), isTrue);
        expect(mockRepo.streamPollAsyncCalled, isTrue);
      });
    });
  });
}
