// ParamValue migration demo — plain objects vs typed ParamValue.
//
// Runs DSN-free with a tiny in-memory fake. Shows the same consumer query
// written with `executeQueryParamValuesFromObjects` (bridge) and with
// `executeQueryParamValues` (`List<ParamValue>`).
//
// Run: dart run example/param_value_migration_demo.dart

import 'package:odbc_fast/odbc_fast.dart';
import 'package:result_dart/result_dart.dart';

class _MigrationDemoService implements IOdbcService {
  static const QueryResult _stubResult = QueryResult(
    columns: ['id', 'name'],
    rows: [
      [1, 'Alice'],
      [2, 'Bob'],
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
    _logParams('executeQueryParamValues', params);
    return const Success(_stubResult);
  }

  void _logParams(String label, List<ParamValue> params) {
    print('  $label params=$params');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'demo fake exposes only executeQueryParamValues for comparison',
      );
}

Future<void> main() async {
  print('ParamValue migration demo (DSN-free fake):');
  print('');

  const connId = 'demo-conn';
  const sql = 'SELECT id, name FROM users WHERE id = ?';
  final service = _MigrationDemoService();

  print('Bridge path — paramValuesFromObjects via extension:');
  final bridged = await service.executeQueryParamValuesFromObjects(
    connId,
    sql,
    const [1],
  );
  bridged.fold(
    (r) => print('  rows=${r.rowCount}'),
    (e) => print('  error: $e'),
  );

  print('');
  print('Preferred path — explicit List<ParamValue>:');
  final typed = await service.executeQueryParamValues(
    connId,
    sql,
    const [ParamValueInt32(1)],
  );
  typed.fold(
    (r) => print('  rows=${r.rowCount}'),
    (e) => print('  error: $e'),
  );

  print('');
  print('Use executeQueryParamValues / executeQueryDirectedParams at call sites.');
}
