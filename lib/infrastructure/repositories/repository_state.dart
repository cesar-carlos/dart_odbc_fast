import 'package:odbc_fast/domain/entities/connection_options.dart';
import 'package:odbc_fast/domain/entities/dart_side_metrics.dart';
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:result_dart/result_dart.dart';

/// Mutable Dart-side state owned by `OdbcRepositoryImpl`.
///
/// Step 1 of the repository split (see
/// `native/doc/repository_split_plan.md`): all maps and metadata
/// helpers are grouped here. The repository façade stays thin for the
/// pieces still living in `odbc_repository_impl.dart`; new runners
/// added in subsequent steps will hold a reference to this state and
/// mutate it through the small documented API below.
///
/// All members are package-private — never expose this through the
/// public barrel.
class OdbcRepositoryState {
  OdbcRepositoryState({this.defaultResultEncoding = ResultEncoding.rowMajor});

  /// Wire encoding used when callers omit `resultEncoding` on param execute
  /// APIs. `ServiceLocator` sets this from
  /// `ResolvedOdbcUsageProfile.recommendedResultEncoding` for server presets.
  ResultEncoding defaultResultEncoding;

  /// Domain `connectionId` (string) → native id (int).
  final Map<String, int> connectionIds = {};

  /// Domain `connectionId` → connection options snapshot used by query
  /// timeout / buffer-size routing.
  final Map<String, ConnectionOptions?> connectionOptions = {};

  /// Domain `connectionId` → original connection string for reconnect.
  final Map<String, String> connectionStrings = {};

  /// Native `stmtId` → ordered named-parameter list captured by
  /// `prepareNamed` so `executePreparedNamed` can convert maps to
  /// positional arguments without re-parsing the SQL.
  final Map<int, List<String>> namedParamOrderByStmtId = {};

  /// Native `stmtId` → owning domain `connectionId`. Lets the
  /// repository reject cross-connection statement misuse.
  final Map<int, String> statementConnectionByStmtId = {};

  /// `poolId` → set of domain `connectionId`s checked out from that
  /// pool. Used to clean up Dart-side state when a pool is closed.
  final Map<int, Set<String>> poolCheckouts = {};

  /// `poolId` → default [ConnectionOptions] applied to connections checked
  /// out from that pool unless overridden in `poolGetConnection`.
  final Map<int, ConnectionOptions?> poolConnectionOptions = {};

  /// Native async request id → owning domain `connectionId`.
  /// Enables `asyncGetResult` to honor per-connection `lazyStrings`.
  final Map<int, String> asyncRequestConnectionById = {};

  /// Domain `connectionId` → owning `poolId` for pooled handles.
  /// Enables O(1) pool membership check and prevents `disconnect()`
  /// being called on pool-acquired connections.
  final Map<String, int> connectionPoolId = {};

  /// Drops every cached metadata entry that belongs to [connectionId].
  /// Called from `disconnect()` and `_onUnderlyingWorkerRecovered`.
  void clearStatementMetadataForConnection(String connectionId) {
    final stmtIdsToRemove = statementConnectionByStmtId.entries
        .where((entry) => entry.value == connectionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final stmtId in stmtIdsToRemove) {
      statementConnectionByStmtId.remove(stmtId);
      namedParamOrderByStmtId.remove(stmtId);
    }
    asyncRequestConnectionById.removeWhere((_, id) => id == connectionId);
  }

  /// Wipes statement metadata across all connections. Used by the
  /// dispose / worker-recovery flow.
  void clearAllStatementMetadata() {
    statementConnectionByStmtId.clear();
    namedParamOrderByStmtId.clear();
  }

  /// Wipes every map. Called on `dispose()` and on
  /// `onWorkerRecovered`.
  void clearAll() {
    connectionIds.clear();
    connectionOptions.clear();
    connectionStrings.clear();
    connectionPoolId.clear();
    poolCheckouts.clear();
    poolConnectionOptions.clear();
    asyncRequestConnectionById.clear();
    clearAllStatementMetadata();
  }

  /// Returns the [ConnectionOptions] for [connectionId] in a single
  /// map lookup so callers that need multiple option fields don't pay
  /// the hash cost twice.
  ConnectionOptions? optionsFor(String connectionId) =>
      connectionOptions[connectionId];

  /// Validates that [stmtId] exists and belongs to [connectionId].
  /// Returns a [Failure] describing the violation, or `null` when the
  /// pair is consistent. The generic [T] is the expected success type
  /// of the calling repository method.
  Failure<T, OdbcError>? validateStatementOwnership<T extends Object>({
    required String connectionId,
    required int stmtId,
    required String operationName,
  }) {
    if (!connectionIds.containsKey(connectionId)) {
      return Failure<T, OdbcError>(
        const ValidationError(message: 'Invalid connection ID'),
      );
    }
    final ownerConnectionId = statementConnectionByStmtId[stmtId];
    if (ownerConnectionId == null) {
      return Failure<T, OdbcError>(
        ValidationError(
          message: 'Unknown statement ID for $operationName. '
              'Prepare statement first.',
        ),
      );
    }
    if (ownerConnectionId != connectionId) {
      return Failure<T, OdbcError>(
        ValidationError(
          message: 'Statement ID $stmtId does not belong '
              'to connection ID $connectionId',
        ),
      );
    }
    return null;
  }

  /// Snapshot of the counters held here. Drives
  /// `OdbcRepositoryImpl.dartSideMetrics()`.
  DartSideMetrics dartSideMetrics() {
    final poolCheckoutTotal = poolCheckouts.values.fold<int>(
      0,
      (sum, set) => sum + set.length,
    );
    return DartSideMetrics(
      connectionCount: connectionIds.length,
      statementCount: statementConnectionByStmtId.length,
      namedParamMetadataCount: namedParamOrderByStmtId.length,
      pooledConnectionCount: connectionPoolId.length,
      poolCheckoutCount: poolCheckoutTotal,
      connectionOptionsCount: connectionOptions.length,
    );
  }
}
