import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/repositories/itelemetry_repository.dart';
import 'package:odbc_fast/domain/services/simple_telemetry_service.dart';
import 'package:odbc_fast/domain/telemetry/entities.dart';
import 'package:result_dart/result_dart.dart';
import 'package:test/test.dart';

class _FailingExporter implements ITelemetryRepository {
  @override
  Future<void> exportTrace(Trace trace) async => throw StateError('export');
  @override
  Future<void> exportSpan(Span span) async => throw StateError('export');
  @override
  Future<void> exportMetric(Metric metric) async => throw StateError('export');
  @override
  Future<void> exportEvent(TelemetryEvent event) async =>
      throw StateError('export');
  @override
  Future<void> updateTrace({
    required String traceId,
    required DateTime endTime,
    Map<String, String> attributes = const {},
  }) async =>
      throw StateError('export');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('should_preserve_sql_result_when_telemetry_fails', () async {
    final diagnostics = <OdbcError>[];
    final telemetry = SimpleTelemetryService(
      _FailingExporter(),
      onDiagnostic: diagnostics.add,
    );
    final success =
        await telemetry.inOperation('query', () async => const Success(7));
    expect(success.getOrNull(), 7);
    const sql = QueryError(message: 'SQL failed', sqlState: '42000');
    final failure = await telemetry.inOperation(
      'query',
      () async => const Failure<int, OdbcError>(sql),
    );
    expect(failure.exceptionOrNull(), same(sql));
    await expectLater(
      telemetry.inOperation<int>('query', () async => throw sql),
      throwsA(same(sql)),
    );
    expect(diagnostics, isNotEmpty);
    expect(diagnostics.every((e) => e.details.cause is StateError), isTrue);
    final trace = telemetry.startTrace('query');
    await telemetry.endTrace(traceId: trace.traceId);
    await expectLater(
      telemetry.endTrace(traceId: trace.traceId),
      throwsException,
    );
  });

  test('should_contain_exceptions_from_diagnostic_callback', () async {
    final telemetry = SimpleTelemetryService(
      _FailingExporter(),
      onDiagnostic: (_) => throw StateError('callback'),
    );
    expect(await telemetry.inOperation('query', () async => 3), 3);
  });
}
