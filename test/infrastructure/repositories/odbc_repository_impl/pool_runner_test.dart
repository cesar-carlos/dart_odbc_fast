
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

import '../../../helpers/fake_async_native_for_errors.dart';
import 'helpers.dart';

void main() {
  group('OdbcRepositoryImpl wave 7b guards and error mapping', () {
    late FakeAsyncNativeForRepositoryErrors native;
    late OdbcRepositoryImpl repository;
    setUp(() async {
      native = FakeAsyncNativeForRepositoryErrors();
      addTearDown(native.dispose);
      repository = OdbcRepositoryImpl(native);
      await repository.initialize();
      final conn = (await repository.connect('Driver={Test}')).getOrNull();
      expect(conn, isNotNull);
    });

    group('dartSideMetrics', () {
      test(
        'should_report_zero_counters_for_fresh_repository',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.connectionCount, 0);
          expect(metrics.statementCount, 0);
          expect(metrics.namedParamMetadataCount, 0);
          expect(metrics.pooledConnectionCount, 0);
          expect(metrics.poolCheckoutCount, 0);
          expect(metrics.connectionOptionsCount, 0);
        },
      );

      test(
        'should_track_connection_count_after_connect',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          await localRepo.connect('Driver={Test}');
          await localRepo.connect('Driver={Test}');

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.connectionCount, 2);
          expect(metrics.connectionOptionsCount, 2);
        },
      );

      test(
        'should_track_statementCount_and_namedParamMetadataCount',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final connId =
              (await localRepo.connect('Driver={Test}')).getOrNull()!.id;
          // The fake returns the same stmtId (100) for every prepare, so the
          // statement map is keyed once. Both prepareNamed and prepare write
          // to the same metadata slot — what matters here is that the maps
          // are populated, not the exact count for distinct stmts.
          await localRepo.prepareNamed(connId, 'SELECT :x');

          final metrics = localRepo.dartSideMetrics();
          expect(metrics.statementCount, greaterThanOrEqualTo(1));
          expect(metrics.namedParamMetadataCount, greaterThanOrEqualTo(1));
        },
      );

      test(
        'should_serialize_to_json_for_telemetry_exporters',
        () async {
          final localNative = FakeRepoNative();
          addTearDown(localNative.dispose);
          final localRepo = OdbcRepositoryImpl(localNative);
          await localRepo.initialize();

          final json = localRepo.dartSideMetrics().toJson();
          expect(
            json.keys,
            containsAll([
              'connectionCount',
              'statementCount',
              'namedParamMetadataCount',
              'pooledConnectionCount',
              'poolCheckoutCount',
              'connectionOptionsCount',
            ]),
          );
        },
      );
    });
  });
}
