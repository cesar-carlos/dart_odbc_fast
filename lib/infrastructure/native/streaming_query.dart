import 'dart:async';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

/// Manages a streaming query result.
///
/// Provides a stream of [ParsedRowBuffer] chunks for processing large
/// result sets incrementally without loading everything into memory.
class StreamingQuery {
  /// Creates a new [StreamingQuery] instance.
  ///
  /// Initializes the stream controller with pause/resume handlers.
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

  /// Stream of parsed row buffers.
  ///
  /// Consumers can listen to this stream to receive query result chunks.
  Stream<ParsedRowBuffer> get stream => _controller.stream;

  /// Adds a chunk of parsed row data to the stream.
  ///
  /// The [chunk] is only added if the stream is not closed and not paused.
  void addChunk(ParsedRowBuffer chunk) {
    if (!_controller.isClosed && !_isPaused) {
      _controller.add(chunk);
    }
  }

  /// Closes the stream.
  ///
  /// After calling this, no more chunks can be added.
  void close() {
    _controller.close();
  }

  /// Cancels the stream asynchronously.
  ///
  /// Closes the stream controller and waits for it to complete.
  Future<void> cancel() async {
    await _controller.close();
  }
}
