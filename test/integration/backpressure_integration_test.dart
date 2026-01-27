import 'dart:async';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ColumnMetadata, ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/streaming_query.dart';
import 'package:test/test.dart';

void main() {
  group('Backpressure Integration', () {
    test('StreamingQuery with maxBufferSize blocks addChunk when buffer full',
        () async {
      const maxBufferSize = 2;
      final query = StreamingQuery(maxBufferSize: maxBufferSize);

      final chunk = ParsedRowBuffer(
        columns: const [ColumnMetadata(name: 'a', odbcType: 2)],
        rows: [
          [1]
        ],
        rowCount: 1,
        columnCount: 1,
      );

      await query.addChunk(chunk);
      await query.addChunk(chunk);
      var thirdCompleted = false;
      final addFuture3 = query.addChunk(chunk).whenComplete(() {
        thirdCompleted = true;
      });
      await Future<void>.delayed(Duration(milliseconds: 50));
      expect(thirdCompleted, isFalse);

      final received = <ParsedRowBuffer>[];
      query.stream.listen((c) => received.add(c));
      await addFuture3;
      await Future<void>.delayed(Duration(milliseconds: 20));
      expect(received.length, 3);
      query.close();
    });

    test('clearBuffer unblocks waiting addChunk', () async {
      final query = StreamingQuery(maxBufferSize: 2);
      final chunk = ParsedRowBuffer(
        columns: const [ColumnMetadata(name: 'a', odbcType: 2)],
        rows: [
          [1]
        ],
        rowCount: 1,
        columnCount: 1,
      );

      await query.addChunk(chunk);
      await query.addChunk(chunk);

      final addFuture = query.addChunk(chunk);
      final cleared = Completer<void>();
      Future<void>.delayed(Duration(milliseconds: 20), () {
        query.clearBuffer();
        cleared.complete();
      });
      await cleared.future;
      await addFuture;
      query.close();
    });
  });
}
