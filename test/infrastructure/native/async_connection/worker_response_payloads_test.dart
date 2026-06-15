import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/isolate/message_protocol.dart';
import 'package:test/test.dart';

import '../../../helpers/load_env.dart';

void main() {
  loadTestEnv();
  group('Worker response payloads', () {
    test('QueryResponse supports TransferableTypedData bytes', () {
      final response = QueryResponse(
        1,
        transferableData: TransferableTypedData.fromList([
          Uint8List.fromList([1, 2, 3]),
        ]),
      );

      expect(response.data, equals(Uint8List.fromList([1, 2, 3])));
    });

    test('StreamFetchResponse keeps inline payload below threshold', () {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes);
      final response = StreamFetchResponse(
        1,
        success: true,
        data: bytes,
      );

      expect(response.data, bytes);
      expect(identical(response.data, response.data), isTrue);
    });

    test('StreamFetchResponse uses transferable payload above threshold', () {
      final bytes = Uint8List(isolateTransferablePayloadThresholdBytes + 1);
      final response = isolateStreamDataResponse(
        requestId: 1,
        success: true,
        data: bytes,
        hasMore: false,
      );

      expect(response.data, bytes);
      expect(identical(response.data, response.data), isTrue);
    });

    test('StreamFetchResponse supports Uint8List bytes', () {
      final bytes = Uint8List.fromList([4, 5, 6]);
      final response = StreamFetchResponse(
        1,
        success: true,
        data: bytes,
      );

      expect(response.data, equals(bytes));
    });
  });
}
