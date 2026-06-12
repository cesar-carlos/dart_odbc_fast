part of 'param_value.dart';

/// Serializes a list of parameter values to binary format.
///
/// The [params] list should contain [ParamValue] instances in the order
/// they appear in the prepared statement.
///
/// Returns a [Uint8List] containing the serialized parameters.
///
/// Uses a two-pass strategy: phase 1 pre-encodes text payloads and computes
/// the exact total byte count; phase 2 writes directly into a single
/// pre-sized [Uint8List] — avoiding all intermediate list allocations and
/// the final [Uint8List.fromList] copy that the old approach required.
Uint8List serializeParams(List<ParamValue> params) {
  if (params.isEmpty) return Uint8List(0);

  // Phase 1: pre-encode text payloads and compute total byte size.
  var totalBytes = 0;
  final encodedText = List<List<int>?>.filled(params.length, null);
  for (var i = 0; i < params.length; i++) {
    switch (params[i]) {
      case ParamValueNull():
        totalBytes += 5;
      case ParamValueString(:final value):
        final b = utf8.encode(value);
        encodedText[i] = b;
        totalBytes += 5 + b.length;
      case ParamValueInt32():
        totalBytes += 9;
      case ParamValueInt64():
        totalBytes += 13;
      case ParamValueDecimal(:final value):
        final b = utf8.encode(value);
        encodedText[i] = b;
        totalBytes += 5 + b.length;
      case ParamValueBinary(:final value):
        totalBytes += 5 + value.length;
      case ParamValueRefCursorOut():
        totalBytes += 5;
    }
  }

  // Phase 2: write all params into the pre-sized buffer.
  final out = Uint8List(totalBytes);
  final bd = ByteData.sublistView(out);
  var off = 0;
  for (var i = 0; i < params.length; i++) {
    switch (params[i]) {
      case ParamValueNull():
        out[off] = _tagNull;
        bd.setUint32(off + 1, 0, _littleEndian);
        off += 5;
      case ParamValueString():
        final b = encodedText[i]!;
        out[off] = _tagString;
        bd.setUint32(off + 1, b.length, _littleEndian);
        out.setRange(off + 5, off + 5 + b.length, b);
        off += 5 + b.length;
      case ParamValueInt32(:final value):
        out[off] = _tagInteger;
        bd.setUint32(off + 1, 4, _littleEndian);
        bd.setInt32(off + 5, value, _littleEndian);
        off += 9;
      case ParamValueInt64(:final value):
        out[off] = _tagBigInt;
        bd.setUint32(off + 1, 8, _littleEndian);
        bd.setInt64(off + 5, value, _littleEndian);
        off += 13;
      case ParamValueDecimal():
        final b = encodedText[i]!;
        out[off] = _tagDecimal;
        bd.setUint32(off + 1, b.length, _littleEndian);
        out.setRange(off + 5, off + 5 + b.length, b);
        off += 5 + b.length;
      case ParamValueBinary(:final value):
        final vLen = value.length;
        out[off] = _tagBinary;
        bd.setUint32(off + 1, vLen, _littleEndian);
        out.setRange(off + 5, off + 5 + vLen, value);
        off += 5 + vLen;
      case ParamValueRefCursorOut():
        out[off] = _tagRefCursorOut;
        bd.setUint32(off + 1, 0, _littleEndian);
        off += 5;
    }
  }

  return out;
}

/// Deserialises a single [ParamValue] from [data] starting at [offset] (mirrors
/// `ParamValue::deserialize` in the Rust engine). Returns the value and the
/// number of bytes consumed.
({ParamValue value, int consumed}) deserializeParamValue(
  Uint8List data, {
  int offset = 0,
}) {
  if (data.length < offset + 5) {
    throw const FormatException('ParamValue buffer too short');
  }
  final tag = data[offset];
  final len = data.buffer.asByteData().getUint32(offset + 1, _littleEndian);
  final consumed = 5 + len;
  if (data.length < offset + consumed) {
    throw const FormatException('ParamValue buffer truncated');
  }
  final start = offset + 5;
  // sublistView avoids copying the payload; the view stays valid as long as
  // the original protocol buffer is alive (held by the enclosing QueryResult).
  final payload = Uint8List.sublistView(data, start, start + len);

  final ParamValue v;
  switch (tag) {
    case _tagNull:
      v = const ParamValueNull();
    case _tagString:
      v = ParamValueString(utf8.decode(payload, allowMalformed: true));
    case _tagInteger:
      if (len != 4) {
        throw const FormatException('ParamValue::Integer expected 4 bytes');
      }
      v = ParamValueInt32(
        ByteData.sublistView(data, start, start + 4).getInt32(0, _littleEndian),
      );
    case _tagBigInt:
      if (len != 8) {
        throw const FormatException('ParamValue::BigInt expected 8 bytes');
      }
      v = ParamValueInt64(
        ByteData.sublistView(data, start, start + 8).getInt64(0, _littleEndian),
      );
    case _tagDecimal:
      v = ParamValueDecimal(utf8.decode(payload, allowMalformed: true));
    case _tagBinary:
      v = ParamValueBinary(payload);
    case _tagRefCursorOut:
      if (len != 0) {
        throw const FormatException(
          'ParamValue::RefCursorOut expected 0 length',
        );
      }
      v = const ParamValueRefCursorOut();
    default:
      throw FormatException('Unknown ParamValue tag: $tag');
  }
  return (value: v, consumed: consumed);
}

/// Deserialises every [ParamValue] in a **legacy** buffer (concatenated
/// encodings, no DRT1 header).
List<ParamValue> deserializeParamValues(Uint8List data) {
  final out = <ParamValue>[];
  var o = 0;
  while (o < data.length) {
    final r = deserializeParamValue(data, offset: o);
    out.add(r.value);
    o += r.consumed;
  }
  return out;
}
