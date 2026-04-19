// X/Open XA / 2PC demo (Sprint 4.3 + 4.3c).
//
// Showcases the full Two-Phase Commit lifecycle via the
// `XaTransactionHandle` + `Xid` API. Demonstrated:
//
//   1. Phase 1 + Phase 2 commit:
//        xaStart → end → prepare → commitPrepared
//   2. 1RM optimisation (fuses prepare + commit on a single RM):
//        xaStart → commitOnePhase
//   3. Crash-recovery flow:
//        xaStart → end → prepare → (process restart) →
//        xaRecover → xaResumePrepared → commitPrepared
//   4. (Bonus) DML-inside-branch — relevant for Oracle, where a
//        branch with no DML returns XA_RDONLY=3 from xa_prepare and
//        Oracle silently auto-completes it (no entry in
//        DBA_PENDING_TRANSACTIONS, nothing to commit prepared).
//
// Engine matrix:
//
//   - PostgreSQL (BEGIN + PREPARE TRANSACTION + pg_prepared_xacts) ✅
//   - MySQL / MariaDB (XA START / END / PREPARE / COMMIT / RECOVER) ✅
//   - DB2 (same SQL grammar as MySQL) ✅
//   - Oracle 10g+ (SYS.DBMS_XA PL/SQL + DBA_PENDING_TRANSACTIONS) ✅ (v3.4.1)
//   - SQL Server (requires MSDTC; build with `--features xa-dtc`) — stub
//   - SQLite / Snowflake / others — UnsupportedFeature (no 2PC)
//
// Run: dart run example/xa_2pc_demo.dart
//
// Requires `EXAMPLE_DSN` (or `ODBC_TEST_DSN`) pointing at PostgreSQL,
// MySQL, DB2, MariaDB or Oracle. The demo gates on `supportsXa` and
// skips with a friendly message when the loaded native library
// predates Sprint 4.3.
//
// Required Oracle privileges (when DSN points at Oracle): the
// connecting user needs EXECUTE on SYS.DBMS_XA (default for SYSTEM),
// FORCE [ANY] TRANSACTION (for crash-recovery), and SELECT on
// DBA_PENDING_TRANSACTIONS. The gvenzl/oracle-xe image used by
// docker compose ships with these enabled out of the box for SYSTEM.

import 'dart:typed_data';

import 'package:odbc_fast/odbc_fast.dart';

import 'common.dart';

void main() async {
  AppLogger.initialize();

  final dsn = requireExampleDsn();
  if (dsn == null) {
    AppLogger.info('EXAMPLE_DSN not set; skipping live XA demo.');
    return;
  }

  final native = NativeOdbcConnection()..initialize();

  if (!native.supportsXa) {
    AppLogger.info(
      'The loaded native library does not export the XA / 2PC FFI '
      'family (Sprint 4.3+). Rebuild the engine from a 3.4+ source '
      'tree or skip this demo.',
    );
    native.dispose();
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    AppLogger.severe('Connect failed: ${native.getError()}');
    native.dispose();
    return;
  }
  AppLogger.info('Connected (native conn id $connId)');

  try {
    // -----------------------------------------------------------------
    // 1. Full 2PC lifecycle: xa_start → end → prepare → commitPrepared.
    //
    // The XID identifies this branch globally; `Xid.fromStrings` UTF-8
    // encodes the gtrid/bqual for you. In a real distributed
    // transaction the Transaction Manager generates the XID and shares
    // it with every Resource Manager.
    // -----------------------------------------------------------------
    AppLogger.info('--- 1. Full 2PC lifecycle (commit) ---');
    final xidA = Xid.fromStrings(
      gtrid: 'demo-2pc-${DateTime.now().microsecondsSinceEpoch}',
      bqual: 'branch-A',
    );
    final xa = native.xaStart(connId, xidA);
    if (xa == null) {
      AppLogger.severe('xaStart failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  Active branch xa_id=${xa.xaId}, state=${xa.state}');

    // ... your DML would run here, on this connection ...

    if (!xa.end()) {
      AppLogger.severe('xa_end failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  After xa_end → state=${xa.state}');

    if (!xa.prepare()) {
      AppLogger.severe('xa_prepare failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  After xa_prepare → state=${xa.state}');

    if (!xa.commitPrepared()) {
      AppLogger.severe('xa_commit_prepared failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  After commit → state=${xa.state}');

    // -----------------------------------------------------------------
    // 2. 1RM optimisation: fuse prepare + commit when this branch is
    //    the sole participant in the global transaction. Avoids the
    //    disk write of the prepare log.
    //
    // **Only safe when no other RM has enlisted in the same global
    // transaction.** A normal Transaction Manager will not pick this
    // path; it's an explicit single-RM shortcut.
    // -----------------------------------------------------------------
    AppLogger.info('--- 2. 1RM optimisation (commit_one_phase) ---');
    final xidB = Xid.fromStrings(
      gtrid: 'demo-1rm-${DateTime.now().microsecondsSinceEpoch}',
      bqual: 'branch-B',
    );
    final xa1rm = native.xaStart(connId, xidB);
    if (xa1rm == null) {
      AppLogger.severe('xaStart failed: ${native.getError()}');
      return;
    }
    if (!xa1rm.commitOnePhase()) {
      AppLogger.severe('commit_one_phase failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  After commit_one_phase → state=${xa1rm.state}');

    // -----------------------------------------------------------------
    // 3. Crash-recovery flow.
    //
    // Simulate the interesting half: prepare a branch, leave it
    // pending, then enumerate it via xaRecover and resume it on a
    // different XaTransactionHandle. In production this is exactly
    // what the Transaction Manager does after a process restart.
    // -----------------------------------------------------------------
    AppLogger.info('--- 3. Crash-recovery flow ---');
    final xidC = Xid(
      formatId: 0,
      gtrid: Uint8List.fromList(
        'demo-recover-${DateTime.now().microsecondsSinceEpoch}'.codeUnits,
      ),
      bqual: Uint8List.fromList('branch-C'.codeUnits),
    );
    final pending = native.xaStart(connId, xidC);
    if (pending == null) {
      AppLogger.severe('xaStart (recovery prep) failed: ${native.getError()}');
      return;
    }
    pending
      ..end()
      ..prepare();
    AppLogger.info('  Prepared but NOT committed: ${pending.xid}');

    // In a real crash-recovery scenario the process would die here.
    // We simulate it by enumerating pending XIDs and resuming xidC by
    // value (not by reusing the `pending` handle).
    final recovered = native.xaRecover(connId);
    if (recovered == null) {
      AppLogger.severe('xaRecover failed: ${native.getError()}');
      return;
    }
    AppLogger.info('  xaRecover returned ${recovered.length} prepared XID(s):');
    for (final x in recovered) {
      AppLogger.info('    - $x');
    }

    final resumed = native.xaResumePrepared(connId, xidC);
    if (resumed == null) {
      AppLogger.severe('xaResumePrepared failed: ${native.getError()}');
      return;
    }
    AppLogger.info(
      '  Resumed handle xa_id=${resumed.xaId}, state=${resumed.state}',
    );

    if (!resumed.commitPrepared()) {
      AppLogger.severe(
        'commitPrepared after resume failed: ${native.getError()}',
      );
      return;
    }
    AppLogger.info('  Recovery commit OK → state=${resumed.state}');

    // -----------------------------------------------------------------
    // 4. Bonus: DML inside the branch.
    //
    // On Oracle a branch with no DML returns XA_RDONLY=3 from
    // xa_prepare and is silently auto-completed by the engine — it
    // never appears in DBA_PENDING_TRANSACTIONS, and the follow-up
    // commitPrepared returns XAER_NOTA which we tolerate as a no-op.
    // For a meaningful 2PC log entry the branch needs at least one
    // INSERT/UPDATE/DELETE. PG / MySQL / MariaDB / DB2 always log,
    // so the same code path works for all engines.
    //
    // The demo creates a tiny scratch table, runs an INSERT inside
    // the branch, prepares + commits, then verifies the row landed.
    // -----------------------------------------------------------------
    AppLogger.info('--- 4. Bonus: DML inside the XA branch ---');
    final tableName = 'xa_demo_${DateTime.now().millisecondsSinceEpoch}';

    // CREATE TABLE outside the XA branch (DDL inside an XA branch is
    // engine-dependent and not what this demo is showing). Wrap in
    // try-finally so we always clean up.
    final created = native.executeQueryParams(
      connId,
      'CREATE TABLE $tableName (k VARCHAR(64))',
      const [],
    );
    if (created == null) {
      AppLogger.severe('  CREATE TABLE failed: ${native.getError()}');
    } else {
      try {
        final xidD = Xid.fromStrings(
          gtrid: 'demo-dml-${DateTime.now().microsecondsSinceEpoch}',
          bqual: 'branch-D',
        );
        final xaDml = native.xaStart(connId, xidD);
        if (xaDml == null) {
          AppLogger.severe('  xaStart (DML) failed: ${native.getError()}');
        } else {
          // The INSERT runs on the same connection that's attached to
          // the branch, so it's recorded against this XID.
          final inserted = native.executeQueryParams(
            connId,
            "INSERT INTO $tableName (k) VALUES ('committed-via-xa')",
            const [],
          );
          if (inserted == null) {
            AppLogger.severe(
              '  INSERT inside XA branch failed: ${native.getError()}',
            );
          } else {
            AppLogger.info('  INSERT inside XA branch OK');
          }

          xaDml
            ..end()
            ..prepare();

          // After PREPARE the row exists logically but is not visible
          // to other sessions. xaRecover should now list xidD.
          final recoveredAfter = native.xaRecover(connId);
          final present = recoveredAfter?.any((x) => x == xidD) ?? false;
          AppLogger.info(
            '  After prepare: branch is in DBA_PENDING_TRANSACTIONS = $present',
          );

          if (!xaDml.commitPrepared()) {
            AppLogger.severe(
              '  commitPrepared (DML) failed: ${native.getError()}',
            );
          } else {
            AppLogger.info('  commitPrepared OK → row is now visible');
          }

          // Verify the row landed.
          final verified = native.executeQueryParams(
            connId,
            "SELECT COUNT(*) FROM $tableName WHERE k = 'committed-via-xa'",
            const [],
          );
          AppLogger.info(
            '  SELECT COUNT(*) returned ${verified?.lengthInBytes ?? 0} bytes '
            '(non-zero ⇒ row visible)',
          );
        }
      } finally {
        native.executeQueryParams(connId, 'DROP TABLE $tableName', const []);
      }
    }
  } finally {
    native
      ..disconnect(connId)
      ..dispose();
    AppLogger.info('Disconnected.');
  }
}
