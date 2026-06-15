import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast_native.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';
import 'fake_workers.dart';

void main() {
  loadTestEnv();
  group('AsyncNativeOdbcConnection bulk insert parallel', () {
    late AsyncNativeOdbcConnection async;

    setUp(() {
      async = AsyncNativeOdbcConnection(
        isolateEntry: fakeWorkerBulkSupport,
      );
    });

    tearDown(() {
      async.dispose();
    });

    test('bulkInsertParallel should return rows inserted', () async {
      await async.initialize();

      final inserted = await async.bulkInsertParallel(
        1,
        't',
        const ['a'],
        Uint8List.fromList([0, 1, 2, 3]),
        4,
      );

      expect(inserted, equals(42));
    });
  });
}
