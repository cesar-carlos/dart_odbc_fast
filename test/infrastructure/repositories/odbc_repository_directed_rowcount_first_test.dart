/// Unit tests: repository mapping for MULT+OUT1 when item[0] is RowCount.
///
/// Verifies that [OdbcRepositoryImpl._parseMultiDirectedBuffer] correctly
/// handles the DML-first case where the Rust engine emits
/// `RowCount(n)` as the very first item in the MULT envelope instead of
/// an empty `ResultSet`.
///
/// Expected behaviour (RowCount-first contract):
///   - Primary [QueryResult] has empty columns/rows/rowCount.
///   - ALL logical items (including the initial RowCount) appear in
///     [QueryResult.additionalResults], preserving order.
///   - [QueryResult.outputParamValues] carries the OUT1 scalar values.
library;

import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart'
    show DirectedResultItem, DirectedRowCountItem, QueryResult;
import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/errors/structured_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/odbc_repository_impl.dart';
import 'package:test/test.dart';

// ─── wire builders ───────────────────────────────────────────────────────────

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

List<int> _le64(int v) {
  final r = <int>[];
  for (var i = 0; i < 8; i++) {
    r.add((v >> (i * 8)) & 0xFF);
  }
  return r;
}

Uint8List _emptyOdbcBuf() {
  final bd = ByteData(16)
    ..setUint32(0, 0x4F444243, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint32(8, 0, Endian.little)
    ..setUint32(12, 0, Endian.little);
  return bd.buffer.asUint8List();
}

Uint8List _multBuf(List<(int, List<int>)> items) {
  final header = <int>[
    ..._le32(0x544C554D),
    0x02, 0x00,
    0x00, 0x00,
    ..._le32(items.length),
  ];
  final body = <int>[];
  for (final (tag, payload) in items) {
    body
      ..add(tag)
      ..addAll(_le32(payload.length))
      ..addAll(payload);
  }
  return Uint8List.fromList([...header, ...body]);
}

List<int> _out1(List<ParamValue> values) {
  const magic = [0x4F, 0x55, 0x54, 0x31];
  final count = _le32(values.length);
  final payloads = values.expand((v) => v.serialize()).toList();
  return [...magic, ...count, ...payloads];
}

// Fake async native stub

class _FakeAsyncNative extends AsyncNativeOdbcConnection {
  _FakeAsyncNative(this._responseBuffer)
      : super(requestTimeout: Duration.zero);

  final Uint8List _responseBuffer;

  @override
  Future<bool> initialize() async => true;

  @override
  Future<int> connect(String connectionString, {int timeoutMs = 0}) async => 1;

  @override
  Future<bool> disconnect(int connectionId) async => true;

  @override
  Future<String> getError() async => '';

  @override
  Future<StructuredError?> getStructuredError() async => null;

  @override
  Future<String?> getAuditStatusJson() async => '[]';

  @override
  Future<String?> getAuditEventsJson({int limit = 0}) async => '{}';

  @override
  Future<String?> poolGetStateJson(int poolId) async => '{}';

  @override
  Future<Uint8List?> executeQueryParamBuffer(
    int connectionId,
    String sql,
    Uint8List? paramBuffer, {
    int? maxBufferBytes,
  }) async =>
      _responseBuffer;

  @override
  void dispose() {}
}

// Helpers

Future<(OdbcRepositoryImpl, String)> _makeRepo(Uint8List buf) async {
  final native = _FakeAsyncNative(buf);
  final repo = OdbcRepositoryImpl(native);
  await repo.initialize();
  final conn = await repo.connect('DSN=Fake');
  final id = conn.getOrNull()!.id;
  return (repo, id);
}

// Tests

void main() {
  group('repository directed OUT — RowCount-first MULT mapping', () {
    test(
      'RowCount then ResultSet then OUT1: '
      'primary empty, all in additionalResults',
      () async {
        final multBody = _multBuf([
          (1, _le64(3)), // RowCount(3) — first logical item
          (0, _emptyOdbcBuf().toList()), // ResultSet
        ]);
        final out1 = _out1([const ParamValueInt32(42)]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final (repo, id) = await _makeRepo(buf);
        final result = await repo.executeQueryParamBuffer(id, 'CALL sp', null);

        expect(result.isSuccess(), isTrue);
        final q = result.getOrNull()!;

        // Primary QueryResult must be empty (no initial cursor).
        expect(q.columns, isEmpty, reason: 'primary columns must be empty');
        expect(q.rows, isEmpty, reason: 'primary rows must be empty');
        expect(q.rowCount, 0, reason: 'primary rowCount must be 0');

        // OUT scalar.
        expect(q.outputParamValues, hasLength(1));
        expect((q.outputParamValues[0] as ParamValueInt32).value, 42);

        // All logical items are in additionalResults.
        expect(q.additionalResults, hasLength(2));
        expect(
          q.additionalResults[0],
          isA<DirectedRowCountItem>(),
          reason: 'additionalResults[0] must be the initial RowCount',
        );
        expect(
          (q.additionalResults[0] as DirectedRowCountItem).rowCount,
          3,
        );
        expect(
          q.additionalResults[1],
          isA<DirectedResultItem>(),
          reason: 'additionalResults[1] must be the ResultSet',
        );
      },
    );

    test(
      'RowCount → RowCount → ResultSet → OUT1: three additionalResults items',
      () async {
        final multBody = _multBuf([
          (1, _le64(1)), // first row-count
          (1, _le64(2)), // second row-count
          (0, _emptyOdbcBuf().toList()), // result set
        ]);
        final out1 = _out1([const ParamValueInt32(7)]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final (repo, id) = await _makeRepo(buf);
        final result = await repo.executeQueryParamBuffer(id, 'CALL sp', null);

        expect(result.isSuccess(), isTrue);
        final q = result.getOrNull()!;

        expect(q.columns, isEmpty);
        expect(q.additionalResults, hasLength(3));
        expect(q.additionalResults[0], isA<DirectedRowCountItem>());
        expect((q.additionalResults[0] as DirectedRowCountItem).rowCount, 1);
        expect(q.additionalResults[1], isA<DirectedRowCountItem>());
        expect((q.additionalResults[1] as DirectedRowCountItem).rowCount, 2);
        expect(q.additionalResults[2], isA<DirectedResultItem>());
      },
    );

    test(
      'ResultSet-first (original path) still maps correctly',
      () async {
        // Regression: the existing ResultSet-first behaviour must be unchanged.
        final multBody = _multBuf([
          (0, _emptyOdbcBuf().toList()), // ResultSet first
          (1, _le64(5)), // RowCount in drain
        ]);
        final out1 = _out1([const ParamValueInt32(99)]);
        final buf = Uint8List.fromList([...multBody, ...out1]);

        final (repo, id) = await _makeRepo(buf);
        final result = await repo.executeQueryParamBuffer(id, 'CALL sp', null);

        expect(result.isSuccess(), isTrue);
        final q = result.getOrNull()!;

        // Primary from first ResultSet.
        expect(q.rowCount, 0); // empty RS
        expect(q.columns, isEmpty);

        // Tail in additionalResults (only the drain item).
        expect(q.additionalResults, hasLength(1));
        expect(q.additionalResults[0], isA<DirectedRowCountItem>());
        expect((q.additionalResults[0] as DirectedRowCountItem).rowCount, 5);

        // OUT scalar.
        expect((q.outputParamValues[0] as ParamValueInt32).value, 99);
      },
    );
  });
}
