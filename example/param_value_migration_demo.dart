// ParamValue migration demo — deprecated untyped params vs typed ParamValue.
//
// Runs DSN-free with a tiny in-memory fake. Shows the same consumer query
// written twice: once with legacy `executeQueryParams` (`List<dynamic>`) and
// once with `executeQueryParamValues` (`List<ParamValue>`).
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
  Future<Result<QueryResult>> executeQueryParams(
    String connectionId,
    String sql,
    List<dynamic> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    _logParams('executeQueryParams (deprecated)', params);
    return const Success(_stubResult);
  }

  @override
  Future<Result<QueryResult>> executeQueryParamValues(
    String connectionId,
    String sql,
    List<ParamValue> params, {
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
  }) async {
    _logParams('executeQueryParamValues (preferred)', params);
    return const Success(_stubResult);
  }

  void _logParams(String label, List<dynamic> params) {
    print('  $label params=$params');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
        'demo fake exposes only the two execute overloads under comparison',
      );
}

Future<void> main() async {
  print('ParamValue migration demo (DSN-free fake):');
  print('');

  const connId = 'demo-conn';
  const sql = 'SELECT id, name FROM users WHERE id = ?';
  final service = _MigrationDemoService();

  print('Legacy path — List<dynamic>:');
  final legacy = await service.executeQueryParams(
    connId,
    sql,
    const [1],
  );
  legacy.fold(
    (r) => print('  rows=${r.rowCount}'),
    (e) => print('  error: $e'),
  );

  print('');
  print('Preferred path — List<ParamValue>:');
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
  print('Migrate call sites to executeQueryParamValues / ');
  print('executeQueryDirectedParams before the next major release.');
}
