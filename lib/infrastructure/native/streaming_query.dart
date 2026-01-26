import 'dart:async';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

class StreamingQuery {

  StreamingQuery()
      : _controller = StreamController<ParsedRowBuffer>(
          onPause: () {},
          onResume: () {},
        ) {
    _controller.onPause = () => _isPaused = true;
    _controller.onResume = () => _isPaused = false;
  }
  final StreamController<ParsedRowBuffer> _controller;
  bool _isPaused = false;

  Stream<ParsedRowBuffer> get stream => _controller.stream;

  void addChunk(ParsedRowBuffer chunk) {
    if (!_controller.isClosed && !_isPaused) {
      _controller.add(chunk);
    }
  }

  void close() {
    _controller.close();
  }

  Future<void> cancel() async {
    await _controller.close();
  }
}
