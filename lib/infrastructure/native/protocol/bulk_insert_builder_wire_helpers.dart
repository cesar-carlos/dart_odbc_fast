part of 'bulk_insert_builder.dart';

final class _BulkEncodeCache {
  _BulkEncodeCache({
    required this.totalBytes,
    required this.tableBytes,
    required this.columnNameBytes,
    required this.v2VariableCells,
  });

  final int totalBytes;
  final Uint8List tableBytes;
  final List<Uint8List> columnNameBytes;

  /// Cached UTF-8/binary cells for v2 variable-length columns; `null` otherwise.
  final List<List<Uint8List>?> v2VariableCells;
}

/// Write cursor for a pre-sized bulk payload buffer.
final class _WriteCursor {
  _WriteCursor(this._out) : _bd = ByteData.sublistView(_out);

  final Uint8List _out;
  final ByteData _bd;
  int offset = 0;

  void writeByte(int v) {
    _out[offset] = v;
    offset++;
  }

  void writeBytes(List<int> bytes) {
    _out.setRange(offset, offset + bytes.length, bytes);
    offset += bytes.length;
  }

  void writeBytesRange(List<int> bytes, int start, int end) {
    _out.setRange(offset, offset + (end - start), bytes, start);
    offset += end - start;
  }

  void writeU16Le(int v) {
    _bd.setUint16(offset, v, _littleEndian);
    offset += 2;
  }

  void writeI16Le(int v) {
    _bd.setInt16(offset, v, _littleEndian);
    offset += 2;
  }

  void writeU32Le(int v) {
    _bd.setUint32(offset, v, _littleEndian);
    offset += 4;
  }

  void writeI32Le(int v) {
    _bd.setInt32(offset, v, _littleEndian);
    offset += 4;
  }

  void writeI64Le(int v) {
    _bd.setInt64(offset, v, _littleEndian);
    offset += 8;
  }

  void writeInt32List(Int32List values) {
    final byteLen = 4 * values.length;
    _out.setRange(
      offset,
      offset + byteLen,
      values.buffer.asUint8List(values.offsetInBytes, byteLen),
    );
    offset += byteLen;
  }

  void writeInt64List(Int64List values) {
    final byteLen = 8 * values.length;
    _out.setRange(
      offset,
      offset + byteLen,
      values.buffer.asUint8List(values.offsetInBytes, byteLen),
    );
    offset += byteLen;
  }
}
