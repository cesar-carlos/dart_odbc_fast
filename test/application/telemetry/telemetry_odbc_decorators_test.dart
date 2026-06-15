/// Component tests for telemetry ODBC capability decorators.
library;

import 'package:odbc_fast/application/services/odbc_service.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_decorators.dart';
import 'package:odbc_fast/application/telemetry/telemetry_odbc_service_decorator.dart';
import 'package:odbc_fast/domain/entities/isolation_level.dart';
import 'package:odbc_fast/domain/entities/transaction_access_mode.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:test/test.dart';

import '../../helpers/mock_odbc_repository.dart';

class _FakeTelemetryRepository implements ITelemetryRepository {
  final List<Trace> traces = [];
  final List<Metric> metrics = [];
  final List<TelemetryEvent> events = [];

  @override
  Future<void> exportTrace(Trace trace) async => traces.add(trace);

  @override
  Future<void> exportSpan(Span span) async {}

  @override
  Future<void> exportMetric(Metric metric) async => metrics.add(metric);

  @override
  Future<void> exportEvent(TelemetryEvent event) async => events.add(event);

  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}

  @override
  Future<void> updateSpan({
    required String spanId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  group('TelemetryOdbcServiceDecorator', () {
    late MockOdbcRepository mockRepo;
    late _FakeTelemetryRepository telemetryRepo;
    late SimpleTelemetryService telemetry;
    late TelemetryOdbcServiceDecorator decorated;

    setUp(() {
      mockRepo = MockOdbcRepository();
      telemetryRepo = _FakeTelemetryRepository();
      telemetry = SimpleTelemetryService(telemetryRepo);
      decorated = TelemetryOdbcServiceDecorator(
        OdbcService(mockRepo),
        telemetry,
      );
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test(
      'should_record_query_operation_trace_when_executeQueryParamValues'
      '_succeeds',
      () async {
        await decorated.initialize();
        final conn = (await decorated.connect('DSN=test')).getOrThrow();

        final result = await decorated.executeQueryParamValues(
          conn.id,
          'SELECT 1',
          const [],
        );

        expect(result.isSuccess(), isTrue);
        expect(mockRepo.executeQueryParamValuesCalled, isTrue);
        expect(
          telemetryRepo.traces.map((t) => t.name),
          contains('ODBC.executeQueryParamValues'),
        );
        expect(
          telemetryRepo.metrics.any(
            (m) => m.name == 'ODBC.executeQueryParamValues.duration',
          ),
          isTrue,
        );
      },
    );

    test('should_record_pool_operation_trace_when_poolCreate_succeeds',
        () async {
      await decorated.initialize();

      final result = await decorated.poolCreate('DSN=pool', 4);

      expect(result.isSuccess(), isTrue);
      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.poolCreate'),
      );
    });

    test(
      'should_record_transaction_operation_trace_when_beginTransaction'
      '_succeeds',
      () async {
        await decorated.initialize();
        final conn = (await decorated.connect('DSN=test')).getOrThrow();

        final result = await decorated.beginTransaction(
          conn.id,
          isolationLevel: IsolationLevel.readCommitted,
          accessMode: TransactionAccessMode.readWrite,
        );

        expect(result.isSuccess(), isTrue);
        expect(mockRepo.beginTransactionCalled, isTrue);
        expect(
          telemetryRepo.traces.map((t) => t.name),
          contains('ODBC.beginTransaction'),
        );
      },
    );

    test('should_record_stream_open_and_close_events_on_streamQuery', () async {
      await decorated.initialize();
      final conn = (await decorated.connect('DSN=test')).getOrThrow();

      final chunks = await decorated.streamQuery(conn.id, 'SELECT 1').toList();

      expect(chunks, isNotEmpty);
      expect(mockRepo.streamQueryCalled, isTrue);
      expect(
        telemetryRepo.events.map((e) => e.name),
        containsAll(['ODBC.streamQuery.open', 'ODBC.streamQuery.close']),
      );
    });

    test('should_expose_narrow_query_service_with_telemetry', () async {
      final queries = decorated.queryService;
      await queries.executeQueryParamValues('conn', 'SELECT 1', const []);

      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.executeQueryParamValues'),
      );
    });
  });

  group('TelemetryOdbcDecorators narrow factories', () {
    late MockOdbcRepository mockRepo;
    late _FakeTelemetryRepository telemetryRepo;
    late SimpleTelemetryService telemetry;
    late OdbcService service;

    setUp(() {
      mockRepo = MockOdbcRepository();
      telemetryRepo = _FakeTelemetryRepository();
      telemetry = SimpleTelemetryService(telemetryRepo);
      service = OdbcService(mockRepo);
    });

    tearDown(() {
      mockRepo.dispose();
    });

    test('should_instrument_IQueryService_via_query_factory', () async {
      final queries = TelemetryOdbcDecorators.query(service, telemetry);

      await queries.executeQueryParamValues('conn', 'SELECT 1', const []);

      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.executeQueryParamValues'),
      );
    });

    test('should_instrument_IPoolService_via_pool_factory', () async {
      final pools = TelemetryOdbcDecorators.pool(service, telemetry);

      await pools.poolCreate('DSN=pool', 2);

      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.poolCreate'),
      );
    });

    test('should_instrument_ITransactionService_via_transaction_factory',
        () async {
      final transactions =
          TelemetryOdbcDecorators.transaction(service, telemetry);

      await transactions.beginTransaction('conn');

      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.beginTransaction'),
      );
    });

    test('should_instrument_IAdminService_via_admin_factory', () async {
      final admin = TelemetryOdbcDecorators.admin(service, telemetry);

      await admin.initialize();

      expect(
        telemetryRepo.traces.map((t) => t.name),
        contains('ODBC.initialize'),
      );
    });
  });
}
