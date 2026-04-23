import 'dart:typed_data';

/// Wire constants for the columnar v2 result layout (row-major v1 remains
/// default). Emitter/parser integration is not wired; see
/// `doc/notes/columnar_protocol_sketch.md` and the Rust `columnar-v2` feature.
///
/// The magic matches the Rust `odbc_engine` crate's
/// `columnar_v2::COLUMNAR_V2_MAGIC` (`u32::from_le_bytes(*b"ODBC")`).
const int columnarV2Magic = 0x4342444F;

/// Returns whether [data] is long enough to carry the sketch header and
/// starts with the v2 magic (little-endian).
bool isLikelyColumnarV2Header(Uint8List data) {
  if (data.length < 4) return false;
  final u32 = ByteData.sublistView(data, 0, 4).getUint32(0, Endian.little);
  return u32 == columnarV2Magic;
}
