/// Policy used when the async worker queue reaches its pending-request cap.
enum AsyncBackpressureMode {
  /// Reject new requests immediately when the queue is full.
  failFast,

  /// Wait for capacity until the configured timeout elapses.
  waitForSlot,
}
