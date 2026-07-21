// Sub-interfaces migration demo for `dart_odbc_fast`.
//
// Two snapshots of the same consumer:
//
// **A)** Tightly coupled to the full `IOdbcService` aggregate. Easy to
//      compose, but the consumer pulls in the entire surface (queries,
//      transactions, pool, admin) even though it only needs queries.
//
// **B)** Refactored to depend on the narrow [IQueryService]. Smaller
//      interface footprint at the seam, friendlier to mocking, and the
//      consumer ignores APIs it doesn't use.
//
// Both versions exercise the new "For" overloads (taking a [Connection]
// directly) so call sites no longer thread `conn.id` strings around.
// V3 adds segregated [IQueryRepository] / [IPoolRepository] getters on
// [ServiceLocator] for repository-layer dependency injection.
//
// The demo runs DSN-free. It instantiates V2 with a tiny in-memory
// fake of [IQueryService] and runs it end-to-end. V1 (which would
// require a fake of the full `IOdbcService` aggregate) is documented
// at the type level — the friction of building that fake is exactly
// what V2's narrower seam removes.

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

/// Version A — depends on the full aggregate `IOdbcService`.
/// Acceptable for small apps; the trade-off is interface bloat at the
/// seam.
class ReportRepositoryV1 {
  ReportRepositoryV1(this._service);

  final IOdbcService _service;

  Future<List<Map<String, dynamic>>> recentEvents(Connection conn) async {
    final r = await _service.executeQueryParamValuesFor(
      conn,
      'SELECT id, occurred_at FROM events ORDER BY occurred_at DESC',
      const [],
    );
    return r.fold(
      (qr) =>
          qr.rows.map((row) => {'id': row[0], 'occurred_at': row[1]}).toList(),
      (_) => const [],
    );
  }
}

/// Version B — depends only on [IQueryService]. The exact same consumer
/// code, but the seam is narrower and easier to mock in tests.
class ReportRepositoryV2 {
  ReportRepositoryV2(this._queries);

  final IQueryService _queries;

  Future<List<Map<String, dynamic>>> recentEvents(Connection conn) async {
    final r = await _queries.executeQueryParamValuesFor(
      conn,
      'SELECT id, occurred_at FROM events ORDER BY occurred_at DESC',
      const [],
    );
    return r.fold(
      (qr) =>
          qr.rows.map((row) => {'id': row[0], 'occurred_at': row[1]}).toList(),
      (_) => const [],
    );
  }
}

/// Tiny in-memory fake exercising only the V2-relevant surface. Anything
/// outside typed query execute falls through to `noSuchMethod` — V2 never
/// touches those, which is exactly the point of depending on the
/// narrow interface.
class _InMemoryQueryService implements IQueryService {
  static const QueryResult _stubResult = QueryResult(
    columns: ['id', 'occurred_at'],
    rows: [
      [1, '2026-05-26T20:00:00Z'],
      [2, '2026-05-26T19:55:00Z'],
    ],
    rowCount: 2,
  );

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding? resultEncoding,
  }) async {
    return const Success(_stubResult);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'demo fake exposes only executeQueryParamValues — '
        'this is the point of IQueryService',
      );
}

Future<void> main() async {
  print('Sub-interfaces migration demo:');
  print('  - V1 depends on IOdbcService (the full aggregate).');
  print('  - V2 depends on IQueryService only.');
  print('  - Both use executeQueryParamValuesFor(Connection conn, ...) to ');
  print('    skip the manual conn.id plumbing.');
  print('');

  // V2 path — the focus of the demo. The fake exposes only the slice
  // V2 actually needs.
  final queryService = _InMemoryQueryService();
  final repoV2 = ReportRepositoryV2(queryService);
  final conn = Connection(
    id: 'demo-conn',
    connectionString: 'DSN=demo',
    createdAt: DateTime.utc(2026),
  );

  final eventsV2 = await repoV2.recentEvents(conn);
  print('V2 (IQueryService only) yielded ${eventsV2.length} rows:');
  for (final row in eventsV2) {
    print('  $row');
  }

  print('');
  print('V1 (IOdbcService aggregate) is described above; it would need ');
  print('a fake covering queries + transactions + pool + admin, '
      'illustrating the cost of depending on the full surface.');

  print('');
  print('V3 — segregated repository getters on ServiceLocator:');
  final locator = ServiceLocator()..initialize();
  final queryRepo = locator.queryRepository;
  final poolRepo = locator.poolRepository;
  print('  queryRepository runtimeType=${queryRepo.runtimeType}');
  print('  poolRepository runtimeType=${poolRepo.runtimeType}');
  print(
    '  same backing instance: ${identical(locator.repository, queryRepo)}',
  );
  locator.shutdown();
}
