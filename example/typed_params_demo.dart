import 'dart:io';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';
import 'package:odbc_fast/odbc_fast.dart';

Future<void> main() async {
  AppLogger.initialize();

  final dsn =
      Platform.environment['ODBC_TEST_DSN'] ?? Platform.environment['ODBC_DSN'];
  if (dsn == null || dsn.trim().isEmpty) {
    AppLogger.warning('Set ODBC_TEST_DSN (or ODBC_DSN) to run this demo.');
    return;
  }

  final native = NativeOdbcConnection();
  if (!native.initialize()) {
    AppLogger.severe('ODBC init failed: ${native.getError()}');
    return;
  }

  final connId = native.connect(dsn);
  if (connId == 0) {
    final se = native.getStructuredError();
    AppLogger.severe(se?.message ?? native.getError());
    return;
  }

  try {
    final bytes = native.executeQueryParams(
      connId,
      'SELECT ? AS a, ? AS b, ? AS c',
      const [
        ParamValueInt32(1),
        ParamValueString('hello'),
        ParamValueNull(),
      ],
    );

    if (bytes == null || bytes.isEmpty) {
      AppLogger.warning('No data returned: ${native.getError()}');
      return;
    }

    final parsed = BinaryProtocolParser.parse(bytes);
    final columnNames = parsed.columns.map((c) => c.name).toList();
    AppLogger.info(
      'columns=$columnNames rows=${parsed.rows}',
    );
  } finally {
    native.disconnect(connId);
  }
}
