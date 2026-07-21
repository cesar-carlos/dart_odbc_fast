// Named parameters demo via the high-level service API.
//
// Covers `@name` / `:name` syntax, repeated placeholders, more than five
// named parameters, and prepared-statement reuse through
// `executeQueryNamed` / `prepareNamed` / `executePreparedNamed`.
//
// Run: dart run example/named_parameters_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    return;
  }

  final locator = ServiceLocator()..initialize();
  final service = locator.syncService;

  final init = await service.initialize();
  if (init.isError()) {
    init.fold((_) {}, (e) => AppLogger.severe('Init failed: $e'));
    return;
  }

  final connResult = await service.connect(dsn);
  final conn = connResult.getOrNull();
  if (conn == null) {
    connResult.fold((_) {}, (e) => AppLogger.severe('Connect failed: $e'));
    locator.shutdown();
    return;
  }

  try {
    await _runAtSyntax(service, conn.id);
    await _runColonSyntax(service, conn.id);
    await _runRepeatedPlaceholderQuery(service, conn.id);
    await _runMoreThanFiveNamedParamsQuery(service, conn.id);
    await _runPreparedReuse(service, conn.id);
  } finally {
    await service.disconnect(conn.id);
    locator.shutdown();
    AppLogger.info('Disconnected');
  }
}

Future<void> _runAtSyntax(IOdbcService service, String connectionId) async {
  final result = await service.executeQueryNamed(
    connectionId,
    'SELECT @name AS name, @age AS age, @active AS active',
    <String, Object?>{
      'name': 'Alice',
      'age': 30,
      'active': true,
    },
  );
  result.fold(
    (rows) => AppLogger.info(
      'At-syntax OK: rows=${rows.rowCount} data=${rows.rows}',
    ),
    (error) => AppLogger.warning('At-syntax unavailable: $error'),
  );
}

Future<void> _runColonSyntax(
  IOdbcService service,
  String connectionId,
) async {
  final result = await service.executeQueryNamed(
    connectionId,
    'SELECT :name AS name, :age AS age, :active AS active',
    <String, Object?>{
      'name': 'Bob',
      'age': 25,
      'active': false,
    },
  );
  result.fold(
    (rows) => AppLogger.info(
      'Colon-syntax OK: rows=${rows.rowCount} data=${rows.rows}',
    ),
    (error) => AppLogger.warning('Colon-syntax unavailable: $error'),
  );
}

Future<void> _runRepeatedPlaceholderQuery(
  IOdbcService service,
  String connectionId,
) async {
  final result = await service.executeQueryNamed(
    connectionId,
    '''
    SELECT
      @id AS first_id,
      @id AS second_id,
      :label AS first_label,
      :label AS second_label
    ''',
    <String, Object?>{
      'id': 77,
      'label': 'shared-value',
    },
  );
  result.fold(
    (rows) {
      final row = rows.rows.isNotEmpty ? rows.rows.first : const <Object?>[];
      AppLogger.info('Repeated placeholders OK: $row');
    },
    (error) => AppLogger.warning(
      'Repeated placeholders unavailable: $error',
    ),
  );
}

Future<void> _runMoreThanFiveNamedParamsQuery(
  IOdbcService service,
  String connectionId,
) async {
  final result = await service.executeQueryNamed(
    connectionId,
    '''
    SELECT
      :a AS a,
      :b AS b,
      :c AS c,
      :d AS d,
      :e AS e,
      :f AS f
    ''',
    <String, Object?>{
      'a': 1,
      'b': 2,
      'c': 3,
      'd': 4,
      'e': 5,
      'f': 6,
    },
  );
  result.fold(
    (rows) {
      final row = rows.rows.isNotEmpty ? rows.rows.first : const <Object?>[];
      AppLogger.info('More than five named params OK: $row');
    },
    (error) => AppLogger.warning(
      'More than five named params unavailable: $error',
    ),
  );
}

Future<void> _runPreparedReuse(
  IOdbcService service,
  String connectionId,
) async {
  final prepared = await service.prepareNamed(
    connectionId,
    'SELECT @name AS name, @age AS age, @active AS active',
  );
  final stmtId = prepared.getOrNull();
  if (stmtId == null) {
    prepared.fold(
      (_) {},
      (error) => AppLogger.warning('prepareNamed unavailable: $error'),
    );
    return;
  }

  final rows = <Map<String, Object?>>[
    <String, Object?>{'name': 'Charlie', 'age': 35, 'active': true},
    <String, Object?>{'name': 'Diana', 'age': 28, 'active': true},
    <String, Object?>{'name': 'Eve', 'age': 42, 'active': false},
  ];

  try {
    for (final params in rows) {
      final result = await service.executePreparedNamed(
        connectionId,
        stmtId,
        params,
        null,
      );
      if (result.isError()) {
        AppLogger.warning(
          'executePreparedNamed failed: ${result.exceptionOrNull()}',
        );
        return;
      }
    }
    AppLogger.info(
      'Reused prepared named statement for ${rows.length} executions',
    );
  } finally {
    await service.closeStatement(connectionId, stmtId);
  }
}
