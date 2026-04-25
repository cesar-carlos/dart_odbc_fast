/// Unit tests for [buildWorkerErrorResponse] in `worker_isolate.dart`.
///
/// Drives the full switch once per concrete [WorkerRequest] so worker
/// error handling stays testable without spinning an isolate.
library;

import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:odbc_fast/infrastructure/native/isolate/worker_isolate.dart';
import 'package:test/test.dart';

void main() {
  const id = 1;
  const err = 'isolate boom';
  final empty = Uint8List(0);

  test('buildWorkerErrorResponse returns matching requestId for every type',
      () {
    final samples = <WorkerRequest>[
      const InitializeRequest(id),
      const SetLogLevelRequest(id, 2),
      const ValidateConnectionStringRequest(id, 'DSN=X'),
      const GetDriverCapabilitiesRequest(id, 'DSN=X'),
      const GetConnectionDbmsInfoRequest(id, 1),
      const ConnectRequest(id, 'DSN=X'),
      const DisconnectRequest(id, 1),
      ExecuteQueryParamsRequest(id, 1, 'SELECT 1', empty),
      const ExecuteQueryMultiRequest(id, 1, 'SELECT 1'),
      ExecuteQueryMultiParamsRequest(id, 1, 'SELECT ?', empty),
      const BeginTransactionRequest(id, 1, 0),
      const CommitTransactionRequest(id, 1),
      const RollbackTransactionRequest(id, 1),
      const SavepointCreateRequest(id, 1, 'sp'),
      const SavepointRollbackRequest(id, 1, 'sp'),
      const SavepointReleaseRequest(id, 1, 'sp'),
      const PrepareRequest(id, 1, 'SELECT 1'),
      ExecutePreparedRequest(id, 1, empty),
      const CancelStatementRequest(id, 1),
      const CloseStatementRequest(id, 1),
      const ClearAllStatementsRequest(id),
      const StreamStartRequest(id, 1, 'SELECT 1'),
      const StreamStartBatchedRequest(id, 1, 'SELECT 1'),
      const StreamStartAsyncRequest(id, 1, 'SELECT 1'),
      const StreamMultiStartBatchedRequest(id, 1, 'SELECT 1'),
      const StreamMultiStartAsyncRequest(id, 1, 'SELECT 1'),
      const StreamPollAsyncRequest(id, 1),
      const StreamFetchRequest(id, 1),
      const StreamCancelRequest(id, 1),
      const StreamCloseRequest(id, 1),
      const PoolCreateRequest(id, 'DSN=X', 4),
      const PoolGetConnectionRequest(id, 1),
      const PoolReleaseConnectionRequest(id, 1),
      const PoolHealthCheckRequest(id, 1),
      const PoolGetStateRequest(id, 1),
      const PoolGetStateJsonRequest(id, 1),
      const PoolSetSizeRequest(id, 1, 8),
      const PoolCloseRequest(id, 1),
      BulkInsertArrayRequest(
        id,
        1,
        't',
        const <String>['c'],
        empty,
        0,
      ),
      BulkInsertParallelRequest(
        id,
        1,
        't',
        const <String>['c'],
        empty,
        2,
      ),
      const GetVersionRequest(id),
      const GetMetricsRequest(id),
      const GetCacheMetricsRequest(id),
      const ClearCacheRequest(id),
      const MetadataCacheEnableRequest(id, maxEntries: 10, ttlSeconds: 30),
      const MetadataCacheStatsRequest(id),
      const MetadataCacheClearRequest(id),
      const CatalogTablesRequest(id, 1),
      const CatalogColumnsRequest(id, 1, 't'),
      const CatalogTypeInfoRequest(id, 1),
      const CatalogPrimaryKeysRequest(id, 1, 't'),
      const CatalogForeignKeysRequest(id, 1, 't'),
      const CatalogIndexesRequest(id, 1, 't'),
      const GetErrorRequest(id),
      const GetStructuredErrorRequest(id),
      const DetectDriverRequest(id, 'DSN=X'),
      const AuditEnableRequest(id, enabled: true),
      const AuditGetEventsRequest(id),
      const AuditGetStatusRequest(id),
      const AuditClearRequest(id),
      const ExecuteAsyncStartRequest(id, 1, 'SELECT 1'),
      const AsyncPollRequest(id, 1),
      const AsyncGetResultRequest(id, 1),
      const AsyncCancelRequest(id, 1),
      const AsyncFreeRequest(id, 1),
    ];

    expect(samples.length, 65,
        reason: 'keep in sync with WorkerRequest subtypes',);

    for (final req in samples) {
      final r = buildWorkerErrorResponse(req, err);
      expect(
        r.requestId,
        id,
        reason: 'type=${req.runtimeType}',
      );
    }
  });

  test('key response shapes match worker contract', () {
    expect(
      buildWorkerErrorResponse(const InitializeRequest(id), err),
      isA<InitializeResponse>().having((r) => r.success, 'success', isFalse),
    );
    final v = buildWorkerErrorResponse(
      const ValidateConnectionStringRequest(id, 'x'),
      err,
    ) as ValidateConnectionStringResponse;
    expect(v.isValid, isFalse);
    expect(v.errorMessage, err);

    final c = buildWorkerErrorResponse(
      const ConnectRequest(id, 'x'),
      err,
    ) as ConnectResponse;
    expect(c.connectionId, 0);
    expect(c.error, err);

    expect(
      buildWorkerErrorResponse(
        const SetLogLevelRequest(id, 1),
        err,
      ),
      isA<BoolResponse>().having((r) => r.value, 'value', isFalse),
    );

    expect(
      buildWorkerErrorResponse(
        ExecuteQueryParamsRequest(id, 1, 's', empty),
        err,
      ),
      isA<QueryResponse>().having((r) => r.error, 'error', err),
    );

    expect(
      buildWorkerErrorResponse(const BeginTransactionRequest(id, 1, 0), err),
      isA<IntResponse>().having((r) => r.value, 'value', 0),
    );

    final sf = buildWorkerErrorResponse(
      const StreamFetchRequest(id, 1),
      err,
    ) as StreamFetchResponse;
    expect(sf.success, isFalse);
    expect(sf.error, err);

    expect(
      buildWorkerErrorResponse(
        BulkInsertArrayRequest(
          id,
          1,
          't',
          const <String>['c'],
          empty,
          0,
        ),
        err,
      ),
      isA<IntResponse>().having((r) => r.value, 'value', -1),
    );

    expect(
      buildWorkerErrorResponse(const PoolGetStateRequest(id, 1), err),
      isA<PoolStateResponse>().having((r) => r.error, 'error', err),
    );

    expect(
      buildWorkerErrorResponse(
        const GetDriverCapabilitiesRequest(id, 'x'),
        err,
      ),
      isA<AuditPayloadResponse>().having((r) => r.error, 'error', err),
    );

    expect(
      buildWorkerErrorResponse(const GetVersionRequest(id), err),
      isA<VersionResponse>(),
    );

    final ge = buildWorkerErrorResponse(
      const GetErrorRequest(id),
      err,
    ) as GetErrorResponse;
    expect(ge.message, err);

    final se = buildWorkerErrorResponse(
      const GetStructuredErrorRequest(id),
      err,
    ) as StructuredErrorResponse;
    expect(se.message, err);
    expect(se.error, err);

    expect(
      buildWorkerErrorResponse(const DetectDriverRequest(id, 'x'), err),
      isA<DetectDriverResponse>().having(
        (r) => r.driverName,
        'driverName',
        isNull,
      ),
    );
  });
}
