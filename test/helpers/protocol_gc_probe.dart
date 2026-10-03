import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/lazy_string.dart';
import 'package:odbc_fast/infrastructure/native/protocol/protocol_byte_accumulator.dart';

@pragma('vm:never-inline')
(Uint8List, ByteData, LazyString) _derivedViews() {
  final accumulator = ProtocolByteAccumulator()
    ..add(Uint8List(65536)..fillRange(0, 65536, 65));
  final parent = accumulator.take(65536);
  final dataAccumulator = ProtocolByteAccumulator()
    ..add(Uint8List(65536)..fillRange(0, 65536, 65));
  final dataParent = dataAccumulator.take(65536);
  final lazyAccumulator = ProtocolByteAccumulator()
    ..add(Uint8List(65536)..fillRange(0, 65536, 65));
  final lazyParent = lazyAccumulator.take(65536);
  return (
    Uint8List.sublistView(parent, 0, 16),
    ByteData.sublistView(dataParent, 16, 32),
    LazyString(Uint8List.sublistView(lazyParent, 32, 48))
  );
}

Future<void> main() async {
  ProtocolByteAccumulator.clearPoolForTest();
  final (bytes, data, text) = _derivedViews();
  final info = await Service.getInfo();
  final socket = await WebSocket.connect(info.serverWebSocketUri.toString());
  final messages = StreamIterator<Object?>(socket);
  try {
    for (var i = 0; i < 5; i++) {
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': '$i',
          'method': 'getAllocationProfile',
          'params': {
            'isolateId': Service.getIsolateId(Isolate.current),
            'gc': true,
          },
        }),
      );
      while (await messages.moveNext()) {
        final response =
            jsonDecode(messages.current! as String) as Map<String, Object?>;
        if (response['id'] == '$i') {
          if (response['error'] != null) {
            throw StateError('${response['error']}');
          }
          break;
        }
      }
    }
    final before = ProtocolByteAccumulator.allocatedBackingBytes;
    final next = ProtocolByteAccumulator()
      ..add(Uint8List(65536)..fillRange(0, 65536, 99));
    stdout.writeln(
      jsonEncode({
        'allocatedBackingBytesAfterGc':
            ProtocolByteAccumulator.allocatedBackingBytes - before,
        'retainedViewsValid': bytes[0] == 65 && data.getUint8(0) == 65,
      }),
    );
    if (bytes[0] != 65 ||
        data.getUint8(0) != 65 ||
        text.value != 'A' * 16 ||
        next.length != 65536) {
      throw StateError('A retained derived view was overwritten');
    }
    stdout.writeln('Retained views survived forced GC and buffer reuse');
  } finally {
    await messages.cancel();
    await socket.close();
  }
}
