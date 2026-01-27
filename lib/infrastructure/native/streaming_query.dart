import 'dart:async';

import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart';

/// Manages a streaming query result with optional buffer-size backpressure.
///
/// When [maxBufferSize] is set, [addChunk] waits when the number of
/// delivered-but-not-consumed chunks would exceed that limit.
class StreamingQuery {
  /// Creates a new [StreamingQuery] instance.
  ///
  /// [maxBufferSize] caps how many chunks can be buffered before the
  /// producer is blocked. Null means unbounded.
  StreamingQuery({this.maxBufferSize})
      : _controller = StreamController<ParsedRowBuffer>(
          onPause: () {},
          onResume: () {},
        ) {
    _controller.onPause = () => _isPaused = true;
    _controller.onResume = () => _isPaused = false;
    _outputStream = _controller.stream.map(_onDeliver);
  }

  /// Maximum number of chunks to buffer. Null = unbounded.
  final int? maxBufferSize;

  final StreamController<ParsedRowBuffer> _controller;
  bool _isPaused = false;
  int _pendingCount = 0;
  Completer<void>? _resumeCompleter;
  late final Stream<ParsedRowBuffer> _outputStream;

  ParsedRowBuffer _onDeliver(ParsedRowBuffer chunk) {
    _pendingCount = (_pendingCount - 1).clamp(0, 0x7FFFFFFF);
    if (maxBufferSize != null &&
        _resumeCompleter != null &&
        _pendingCount < maxBufferSize!) {
      _resumeCompleter!.complete();
      _resumeCompleter = null;
    }
    return chunk;
  }

  /// Stream of parsed row buffers.
  ///
  /// Listen to this stream to receive query result chunks. When
  /// [maxBufferSize] is set, backpressure is applied to producers
  /// that call [addChunk].
  Stream<ParsedRowBuffer> get stream => _outputStream;

  /// Adds a chunk. When [maxBufferSize] is set and the buffer is full,
  /// waits until the consumer reduces the count below [maxBufferSize].
  Future<void> addChunk(ParsedRowBuffer chunk) async {
    if (_controller.isClosed) return;
    if (_isPaused && maxBufferSize == null) return;

    if (maxBufferSize != null && _pendingCount >= maxBufferSize!) {
      _resumeCompleter ??= Completer<void>();
      await _resumeCompleter!.future;
      if (_controller.isClosed) return;
    }
    _pendingCount++;
    if (!_controller.isClosed) {
      _controller.add(chunk);
    }
  }

  /// Resets the pending count and unblocks any producer waiting on
  /// backpressure. Does not remove already-added events from the stream.
  void clearBuffer() {
    _pendingCount = 0;
    if (_resumeCompleter != null) {
      _resumeCompleter!.complete();
      _resumeCompleter = null;
    }
  }

  /// Closes the stream.
  void close() {
    _controller.close();
    if (_resumeCompleter != null) {
      _resumeCompleter!.complete();
      _resumeCompleter = null;
    }
  }

  /// Cancels the stream asynchronously.
  Future<void> cancel() async {
    await _controller.close();
  }
}
