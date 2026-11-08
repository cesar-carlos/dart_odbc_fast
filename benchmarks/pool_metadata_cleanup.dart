import 'dart:convert';

import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';

// Historical implementation, measured in the same AOT executable.
class _Baseline extends OdbcRepositoryState {
  @override
  void clearStatementMetadataForConnection(String connectionId) {
    uncertainConnections.remove(connectionId);
    final ids = statementConnectionByStmtId.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final id in ids) {
      statementConnectionByStmtId.remove(id);
      namedParamOrderByStmtId.remove(id);
    }
    transactionStates
        .removeWhere((id, _) => transactionOwners[id] == connectionId);
    transactionOwners.removeWhere((_, id) => id == connectionId);
    xaTransactions.remove(connectionId);
    asyncRequestConnectionById.removeWhere((_, id) => id == connectionId);
  }
}

OdbcRepositoryState fixture(int size, int stride, {required bool baseline}) {
  final state = baseline ? _Baseline() : OdbcRepositoryState();
  for (var i = 0; i < size; i++) {
    state.statementConnectionByStmtId[i] =
        stride != 0 && i % stride == 0 ? 'target' : 'other';
    if (i.isEven) state.namedParamOrderByStmtId[i] = const ['value'];
  }
  return state;
}

void main() {
  final results = <String, Object>{};
  var checksum = 0;
  for (final size in [0, 8, 256, 4096]) {
    for (final stride in [0, 1, 4]) {
      if (size == 0 && stride != 0) continue;
      final check = fixture(size, stride, baseline: false)
        ..clearStatementMetadataForConnection('target');
      final reference = fixture(size, stride, baseline: true)
        ..clearStatementMetadataForConnection('target');
      if (check.statementConnectionByStmtId.toString() !=
              reference.statementConnectionByStmtId.toString() ||
          check.namedParamOrderByStmtId.toString() !=
              reference.namedParamOrderByStmtId.toString()) {
        throw StateError('Cleanup output differs');
      }
      final before = <double>[];
      final after = <double>[];
      const batchSize = 64;
      for (var sample = -20; sample < 31; sample++) {
        final baseline = List.generate(
          batchSize,
          (_) => fixture(size, stride, baseline: true),
        );
        final candidate = List.generate(
          batchSize,
          (_) => fixture(size, stride, baseline: false),
        );
        double measure(List<OdbcRepositoryState> states) {
          final watch = Stopwatch()..start();
          for (final state in states) {
            state.clearStatementMetadataForConnection('target');
          }
          watch.stop();
          for (final state in states) {
            checksum += state.statementConnectionByStmtId.length;
          }
          return watch.elapsedTicks * 1e6 / watch.frequency / batchSize;
        }

        final double oldTime;
        final double newTime;
        if (sample.isEven) {
          oldTime = measure(baseline);
          newTime = measure(candidate);
        } else {
          newTime = measure(candidate);
          oldTime = measure(baseline);
        }
        if (sample >= 0) {
          before.add(oldTime);
          after.add(newTime);
        }
      }
      results['statements_${size}_stride_$stride'] = {
        'baselineMicros': before,
        'candidateMicros': after,
      };
    }
  }
  print(jsonEncode({'samples': results, 'checksum': checksum}));
}
