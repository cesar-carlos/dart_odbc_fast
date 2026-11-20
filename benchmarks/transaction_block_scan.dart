import 'dart:convert';

import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';

// Experimental replacement for the local ownership scan at 9bf7d80.
class _KeyScan extends OdbcRepositoryState {
  @override
  OdbcError? transactionBlock(String connectionId) {
    var blocked = false;
    for (final id in transactionOwners.keys) {
      if (transactionOwners[id] != connectionId) continue;
      final state = transactionStates[id];
      if (state != null && state != LocalTransactionState.active) {
        blocked = true;
        break;
      }
    }
    final xaBlocked =
        xaTransactions[connectionId]?.any((h) => h.outcomeUnknown) ?? false;
    if (!blocked &&
        !xaBlocked &&
        !uncertainConnections.contains(connectionId)) {
      return null;
    }
    return QueryError(
      message: 'The transaction outcome is not confirmed',
      details: OdbcErrorDetails(
        code: OdbcErrorCode.transaction,
        connectionId: connectionId,
        outcomeUnknown: true,
      ),
    );
  }
}

// Production implementation at 9bf7d80.
class _Baseline extends OdbcRepositoryState {
  @override
  OdbcError? transactionBlock(String connectionId) {
    final blocked = transactionOwners.entries.any(
      (entry) =>
          entry.value == connectionId &&
          transactionStates[entry.key] != null &&
          transactionStates[entry.key] != LocalTransactionState.active,
    );
    final xaBlocked =
        xaTransactions[connectionId]?.any((h) => h.outcomeUnknown) ?? false;
    if (!blocked &&
        !xaBlocked &&
        !uncertainConnections.contains(connectionId)) {
      return null;
    }
    return QueryError(
      message: 'The transaction outcome is not confirmed',
      details: OdbcErrorDetails(
        code: OdbcErrorCode.transaction,
        connectionId: connectionId,
        outcomeUnknown: true,
      ),
    );
  }
}

Object? signature(OdbcError? error) => error == null
    ? null
    : (
        error.runtimeType,
        error.message,
        error.code,
        error.details.connectionId,
        error.details.outcomeUnknown,
      );

int checksum = 0;

double measure(OdbcRepositoryState state, List<String> ids, int rounds) {
  var blocked = 0;
  final timer = Stopwatch()..start();
  for (var i = 0; i < rounds; i++) {
    if (state.transactionBlock(ids[i % ids.length]) != null) blocked++;
  }
  timer.stop();
  checksum += blocked;
  return timer.elapsedTicks * 1e9 / timer.frequency / rounds;
}

void main(List<String> args) {
  final results = <String, Object>{};
  for (final count in [0, 1, 8, 256, 4096]) {
    final baseline = _Baseline();
    final candidate =
        args.contains('--keys') ? _KeyScan() : OdbcRepositoryState();
    for (final state in [baseline, candidate]) {
      for (var i = 0; i < count; i++) {
        state.transactionOwners[i] = 'c$i';
        state.transactionStates[i] = LocalTransactionState.active;
      }
    }
    final workloads = {
      'allowed': ['absent', 'c0', 'c${count - 1}'],
      'mixed': ['absent', 'c0', 'uncertain', 'c${count - 1}'],
    };
    for (final workload in workloads.entries) {
      if (workload.key == 'mixed') {
        for (final state in [baseline, candidate]) {
          state.uncertainConnections.add('uncertain');
          if (count == 0) continue;
          state.transactionStates[0] = LocalTransactionState.finishing;
          state.transactionStates[count - 1] = LocalTransactionState.unknown;
        }
      }
      for (final id in workload.value) {
        if (signature(baseline.transactionBlock(id)) !=
            signature(candidate.transactionBlock(id))) {
          throw StateError('Decision or diagnostic differs for $id');
        }
      }
      final rounds = (100000 ~/ (count + 1)).clamp(64, 65536);
      final before = <double>[];
      final after = <double>[];
      for (var pair = -15; pair < 31; pair++) {
        final double oldTime;
        final double newTime;
        if (pair.isEven) {
          oldTime = measure(baseline, workload.value, rounds);
          newTime = measure(candidate, workload.value, rounds);
        } else {
          newTime = measure(candidate, workload.value, rounds);
          oldTime = measure(baseline, workload.value, rounds);
        }
        if (pair >= 0) {
          before.add(oldTime);
          after.add(newTime);
        }
      }
      results['${workload.key}_$count'] = {
        'baseline': before,
        'candidate': after,
      };
    }
  }
  print(jsonEncode({'nsPerCall': results, 'checksum': checksum}));
}
