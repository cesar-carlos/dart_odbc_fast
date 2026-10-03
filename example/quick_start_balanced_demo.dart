// Small results: balanced profile, typed parameters and Result errors.
// Run: dart run example/quick_start_balanced_demo.dart

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

Future<void> main() =>
    withExampleConnection((locator, service, connection) async {
      final queries = locator.queryService;
      final result = (await queries.executeQueryParamValues(
        connection.id,
        'SELECT CAST(? AS INTEGER) AS id',
        const [ParamValueInt32(1)],
      ))
          .getOrThrow();
      final reader = result.reader();
      final id = reader.scalar<int>('id', ignoreCase: true);
      reportExampleProgress(
        'profile=${locator.resolvedUsageProfile.profile.name} '
        'rows=${result.rowCount} id=$id',
      );
    });
