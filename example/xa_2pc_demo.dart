// X/Open XA / 2PC demo (NEW in Sprint 4.3).
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
//
// Engine matrix:
//
//   - PostgreSQL (BEGIN + PREPARE TRANSACTION + pg_prepared_xacts) ✅
//   - MySQL / MariaDB (XA START / END / PREPARE / COMMIT / RECOVER) ✅
//   - DB2 (same SQL grammar as MySQL) ✅
//   - SQL Server (requires MSDTC; build with `--features xa-dtc`) — stub
//   - Oracle (requires OCI XA; build with `--features xa-oci`) — stub
//   - SQLite / Snowflake / others — UnsupportedFeature (no 2PC)
//
// Run: dart run example/xa_2pc_demo.dart
//
// Requires `EXAMPLE_DSN` (or `ODBC_TEST_DSN`) pointing at PostgreSQL,
// MySQL or DB2. The demo gates on `supportsXa` and skips with a
// friendly message when the loaded native library predates Sprint 4.3.

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
  } finally {
    native
      ..disconnect(connId)
      ..dispose();
    AppLogger.info('Disconnected.');
  }
}
