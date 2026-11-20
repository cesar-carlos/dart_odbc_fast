import 'dart:convert';
import 'dart:typed_data';

import 'package:odbc_fast/infrastructure/native/protocol/protocol_ascii_parse.dart';

bool original(Uint8List data) {
  for (var i = 0; i < data.length; i++) {
    if (data[i] > 127) return false;
  }
  return true;
}

void main() {
  final samples = <String, List<double>>{};
  var checksum = 0;
  for (final n in [8, 64, 512, 4096]) {
    for (final position in [-1, 0, n - 1]) {
      final data = Uint8List.sublistView(Uint8List(n + 1), 1);
      if (position >= 0) data[position] = 0xff;
      if (original(data) != isAsciiBytes(data)) {
        throw StateError('ASCII mismatch');
      }
      for (var pair = -10; pair < 31; pair++) {
        for (final old in pair.isEven ? [true, false] : [false, true]) {
          final scan = old ? original : isAsciiBytes;
          final rounds = (1000000 ~/ n).clamp(1000, 50000);
          final timer = Stopwatch()..start();
          for (var i = 0; i < rounds; i++) {
            if (scan(data)) checksum++;
          }
          timer.stop();
          if (pair >= 0) {
            (samples['${n}_${position}_$old'] ??= [])
                .add(timer.elapsedTicks * 1e9 / timer.frequency / rounds);
          }
        }
      }
    }
  }
  print(jsonEncode({'ns': samples, 'checksum': checksum}));
}
