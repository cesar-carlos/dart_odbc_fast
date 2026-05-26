/// Unit tests for [OdbcRepositoryState] — Step 1 of the repository split.
library;

import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:test/test.dart';

void main() {
  group('OdbcRepositoryState', () {
    late OdbcRepositoryState state;

    setUp(() {
      state = OdbcRepositoryState();
    });

    test('should_report_zero_counters_when_empty', () {
      final m = state.dartSideMetrics();
      expect(m.connectionCount, 0);
      expect(m.statementCount, 0);
      expect(m.namedParamMetadataCount, 0);
      expect(m.pooledConnectionCount, 0);
      expect(m.poolCheckoutCount, 0);
      expect(m.connectionOptionsCount, 0);
    });

    test('should_aggregate_counters_after_populating_maps', () {
      state.connectionIds['c1'] = 1;
      state.connectionIds['c2'] = 2;
      state.connectionOptions['c1'] = const ConnectionOptions();
      state.statementConnectionByStmtId[100] = 'c1';
      state.namedParamOrderByStmtId[100] = ['x', 'y'];
      state.connectionPoolId['p1'] = 9;
      state.poolCheckouts[9] = {'p1', 'p2'};

      final m = state.dartSideMetrics();
      expect(m.connectionCount, 2);
      expect(m.statementCount, 1);
      expect(m.namedParamMetadataCount, 1);
      expect(m.pooledConnectionCount, 1);
      expect(m.poolCheckoutCount, 2);
      expect(m.connectionOptionsCount, 1);
    });

    test(
      'clearStatementMetadataForConnection_drops_only_target_stmts',
      () {
        state.statementConnectionByStmtId[10] = 'c1';
        state.statementConnectionByStmtId[20] = 'c2';
        state.statementConnectionByStmtId[30] = 'c1';
        state.namedParamOrderByStmtId[10] = ['a'];
        state.namedParamOrderByStmtId[30] = ['b'];

        state.clearStatementMetadataForConnection('c1');

        expect(state.statementConnectionByStmtId.containsKey(10), isFalse);
        expect(state.statementConnectionByStmtId.containsKey(20), isTrue);
        expect(state.statementConnectionByStmtId.containsKey(30), isFalse);
        expect(state.namedParamOrderByStmtId.containsKey(10), isFalse);
        expect(state.namedParamOrderByStmtId.containsKey(30), isFalse);
      },
    );

    test('clearAll_wipes_every_map', () {
      state.connectionIds['c1'] = 1;
      state.connectionStrings['c1'] = 'DSN=Foo';
      state.connectionPoolId['c1'] = 9;
      state.poolCheckouts[9] = {'c1'};
      state.statementConnectionByStmtId[1] = 'c1';
      state.namedParamOrderByStmtId[1] = ['x'];

      state.clearAll();

      expect(state.connectionIds, isEmpty);
      expect(state.connectionStrings, isEmpty);
      expect(state.connectionPoolId, isEmpty);
      expect(state.poolCheckouts, isEmpty);
      expect(state.statementConnectionByStmtId, isEmpty);
      expect(state.namedParamOrderByStmtId, isEmpty);
    });

    group('validateStatementOwnership', () {
      test('returns_invalid_connectionId_when_unknown', () {
        final f = state.validateStatementOwnership<Object>(
          connectionId: 'missing',
          stmtId: 1,
          operationName: 'op',
        );
        expect(f, isNotNull);
        expect(
          (f!.exceptionOrNull() as ValidationError).message,
          equals('Invalid connection ID'),
        );
      });

      test('returns_unknown_stmtId_when_orphaned', () {
        state.connectionIds['c1'] = 1;
        final f = state.validateStatementOwnership<Object>(
          connectionId: 'c1',
          stmtId: 99,
          operationName: 'fakeOp',
        );
        expect(f, isNotNull);
        expect(
          (f!.exceptionOrNull() as ValidationError).message,
          contains('fakeOp'),
        );
      });

      test('returns_cross_connection_when_stmt_belongs_to_other_conn', () {
        state.connectionIds['c1'] = 1;
        state.connectionIds['c2'] = 2;
        state.statementConnectionByStmtId[10] = 'c2';

        final f = state.validateStatementOwnership<Object>(
          connectionId: 'c1',
          stmtId: 10,
          operationName: 'op',
        );
        expect(f, isNotNull);
        expect(
          (f!.exceptionOrNull() as ValidationError).message,
          contains('does not belong'),
        );
      });

      test('returns_null_when_stmt_belongs_to_caller', () {
        state.connectionIds['c1'] = 1;
        state.statementConnectionByStmtId[10] = 'c1';

        final f = state.validateStatementOwnership<Object>(
          connectionId: 'c1',
          stmtId: 10,
          operationName: 'op',
        );
        expect(f, isNull);
      });
    });
  });
}
