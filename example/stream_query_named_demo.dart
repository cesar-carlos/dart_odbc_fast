// Demo of `streamQueryNamed`: named-parameter query exposed as a Stream.
//
// Use case: prefer the streaming API for uniform call sites where some queries
// could be incremental (large result sets) and others are small. With
// `streamQueryNamed` you get the same single-chunk delivery contract as
// `executeQueryNamed` but wrapped in a Stream<Result<QueryResult>> so consumers
// don't have to branch between async/await and await-for.
//
// Run: dart run example/stream_query_named_demo.dart
//
// Requires ODBC_TEST_DSN or ODBC_DSN in .env or the environment.

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.service;

  final init = await service.initialize();
  if (init.isError()) {
    AppLogger.severe('initialize failed: ${init.exceptionOrNull()}');
    locator.shutdown();
    return;
  }

  final connResult = await service.connect(
    dsn,
    options: locator.recommendedConnectionOptions,
  );
  if (connResult.isError()) {
    AppLogger.severe('connect failed: ${connResult.exceptionOrNull()}');
    locator.shutdown();
    return;
  }
  final conn = connResult.getOrElse(
    (_) => throw Exception('connect succeeded but value missing'),
  );

  try {
    await _runHappyPath(service, conn.id);
    await _runMissingNamedParam(service, conn.id);
  } finally {
    await service.disconnect(conn.id);
  }
  locator.shutdown();
}

Future<void> _runHappyPath(IOdbcService service, String connectionId) async {
  // Use a portable expression that works on any ODBC backend without a
  // table. The named parameters are resolved client-side, then the query
  // is forwarded to the engine as a positional-parameter SELECT.
  final stream = service.streamQueryNamed(
    connectionId,
    'SELECT @id AS id, :label AS label',
    <String, Object?>{'id': 42, 'label': 'streamQueryNamed-demo'},
  );

  // The stream yields exactly one chunk (the full result) for a successful
  // call. Iterate with await-for to keep the call site uniform with truly
  // incremental APIs like `streamQuery`.
  await for (final chunk in stream) {
    chunk.fold(
      (qr) => AppLogger.info(
        'happy: rows=${qr.rowCount} columns=${qr.columns} '
        'first=${qr.rows.isEmpty ? "[]" : qr.rows.first}',
      ),
      (e) => AppLogger.warning('happy: failure $e'),
    );
  }
}

Future<void> _runMissingNamedParam(
  IOdbcService service,
  String connectionId,
) async {
  // Demonstrates failure surface: a missing named parameter is reported as
  // a single Failure(ValidationError) item on the stream, never as a thrown
  // exception. The stream still completes after that one item.
  final stream = service.streamQueryNamed(
    connectionId,
    'SELECT :missing AS x',
    const <String, Object?>{},
  );

  await for (final chunk in stream) {
    chunk.fold(
      (qr) => AppLogger.warning(
        'missing-param: unexpected success rows=${qr.rowCount}',
      ),
      (e) => AppLogger.info('missing-param: surfaced as $e'),
    );
  }
}
