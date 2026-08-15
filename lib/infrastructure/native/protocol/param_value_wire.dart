part of 'param_value.dart';

bool _isAsciiOnly(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) > 0x7F) {
      return false;
    }
  }
  return true;
}

void _writeAsciiString(Uint8List out, int offset, String value) {
  for (var i = 0; i < value.length; i++) {
    out[offset + i] = value.codeUnitAt(i);
  }
}

/// Serializes a list of parameter values to binary format.
///
/// The [params] list should contain [ParamValue] instances in the order
/// they appear in the prepared statement.
///
/// Returns a [Uint8List] containing the serialized parameters.
///
/// Uses a two-pass strategy: phase 1 sizes the buffer (ASCII text writes
/// code units directly in phase 2; non-ASCII is UTF-8 encoded once);
/// phase 2 writes into a single pre-sized [Uint8List].
Uint8List serializeParams(List<ParamValue> params) {
  if (params.isEmpty) return Uint8List(0);

  // Phase 1: size payloads. `encodedText?[i] == null` means ASCII (or unused);
  // non-null holds a one-shot UTF-8 encoding for non-ASCII text. The list is
  // allocated lazily — skipped entirely when all params are integers/nulls.
  var totalBytes = 0;
  List<List<int>?>? encodedText;
  for (var i = 0; i < params.length; i++) {
    switch (params[i]) {
      case ParamValueNull():
        totalBytes += 5;
      case ParamValueString(:final value):
        if (_isAsciiOnly(value)) {
          totalBytes += 5 + value.length;
        } else {
          final b = utf8.encode(value);
          (encodedText ??= List<List<int>?>.filled(params.length, null))[i] =
              b;
          totalBytes += 5 + b.length;
        }
      case ParamValueInt32():
        totalBytes += 9;
      case ParamValueInt64():
        totalBytes += 13;
      case ParamValueDecimal(:final value):
        if (_isAsciiOnly(value)) {
          totalBytes += 5 + value.length;
        } else {
          final b = utf8.encode(value);
          (encodedText ??= List<List<int>?>.filled(params.length, null))[i] =
              b;
          totalBytes += 5 + b.length;
        }
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
      case ParamValueString(:final value):
        final encoded = encodedText?[i];
        if (encoded != null) {
          out[off] = _tagString;
          bd.setUint32(off + 1, encoded.length, _littleEndian);
          out.setRange(off + 5, off + 5 + encoded.length, encoded);
          off += 5 + encoded.length;
        } else {
          out[off] = _tagString;
          bd.setUint32(off + 1, value.length, _littleEndian);
          _writeAsciiString(out, off + 5, value);
          off += 5 + value.length;
        }
      case ParamValueInt32(:final value):
        out[off] = _tagInteger;
        bd
          ..setUint32(off + 1, 4, _littleEndian)
          ..setInt32(off + 5, value, _littleEndian);
        off += 9;
      case ParamValueInt64(:final value):
        out[off] = _tagBigInt;
        bd
          ..setUint32(off + 1, 8, _littleEndian)
          ..setInt64(off + 5, value, _littleEndian);
        off += 13;
      case ParamValueDecimal(:final value):
        final encoded = encodedText?[i];
        if (encoded != null) {
          out[off] = _tagDecimal;
          bd.setUint32(off + 1, encoded.length, _littleEndian);
          out.setRange(off + 5, off + 5 + encoded.length, encoded);
          off += 5 + encoded.length;
        } else {
          out[off] = _tagDecimal;
          bd.setUint32(off + 1, value.length, _littleEndian);
          _writeAsciiString(out, off + 5, value);
          off += 5 + value.length;
        }
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

/// Serializes directed parameters as **DRT1** (magic + count + direction +
/// ParamValue payload per entry) using the same two-pass writer as
/// [serializeParams].
Uint8List serializeDirectedParamList(
  List<int> directions,
  List<ParamValue> params,
) {
  if (directions.length != params.length) {
    throw ArgumentError(
      'directions.length (${directions.length}) != params.length '
      '(${params.length})',
    );
  }
  if (params.isEmpty) {
    final empty = Uint8List(8);
    empty[0] = 0x44; // D
    empty[1] = 0x52; // R
    empty[2] = 0x54; // T
    empty[3] = 0x31; // 1
    // count = 0 already
    return empty;
  }

  var totalBytes = 8; // magic(4) + count(4)
  List<List<int>?>? encodedText;
  for (var i = 0; i < params.length; i++) {
    totalBytes += 1; // direction
    switch (params[i]) {
      case ParamValueNull():
        totalBytes += 5;
      case ParamValueString(:final value):
        if (_isAsciiOnly(value)) {
          totalBytes += 5 + value.length;
        } else {
          final b = utf8.encode(value);
          (encodedText ??= List<List<int>?>.filled(params.length, null))[i] =
              b;
          totalBytes += 5 + b.length;
        }
      case ParamValueInt32():
        totalBytes += 9;
      case ParamValueInt64():
        totalBytes += 13;
      case ParamValueDecimal(:final value):
        if (_isAsciiOnly(value)) {
          totalBytes += 5 + value.length;
        } else {
          final b = utf8.encode(value);
          (encodedText ??= List<List<int>?>.filled(params.length, null))[i] =
              b;
          totalBytes += 5 + b.length;
        }
      case ParamValueBinary(:final value):
        totalBytes += 5 + value.length;
      case ParamValueRefCursorOut():
        totalBytes += 5;
    }
  }

  final out = Uint8List(totalBytes);
  final bd = ByteData.sublistView(out);
  out[0] = 0x44;
  out[1] = 0x52;
  out[2] = 0x54;
  out[3] = 0x31;
  bd.setUint32(4, params.length, _littleEndian);
  var off = 8;
  for (var i = 0; i < params.length; i++) {
    out[off++] = directions[i];
    switch (params[i]) {
      case ParamValueNull():
        out[off] = _tagNull;
        bd.setUint32(off + 1, 0, _littleEndian);
        off += 5;
      case ParamValueString(:final value):
        final encoded = encodedText?[i];
        if (encoded != null) {
          out[off] = _tagString;
          bd.setUint32(off + 1, encoded.length, _littleEndian);
          out.setRange(off + 5, off + 5 + encoded.length, encoded);
          off += 5 + encoded.length;
        } else {
          out[off] = _tagString;
          bd.setUint32(off + 1, value.length, _littleEndian);
          _writeAsciiString(out, off + 5, value);
          off += 5 + value.length;
        }
      case ParamValueInt32(:final value):
        out[off] = _tagInteger;
        bd
          ..setUint32(off + 1, 4, _littleEndian)
          ..setInt32(off + 5, value, _littleEndian);
        off += 9;
      case ParamValueInt64(:final value):
        out[off] = _tagBigInt;
        bd
          ..setUint32(off + 1, 8, _littleEndian)
          ..setInt64(off + 5, value, _littleEndian);
        off += 13;
      case ParamValueDecimal(:final value):
        final encoded = encodedText?[i];
        if (encoded != null) {
          out[off] = _tagDecimal;
          bd.setUint32(off + 1, encoded.length, _littleEndian);
          out.setRange(off + 5, off + 5 + encoded.length, encoded);
          off += 5 + encoded.length;
        } else {
          out[off] = _tagDecimal;
          bd.setUint32(off + 1, value.length, _littleEndian);
          _writeAsciiString(out, off + 5, value);
          off += 5 + value.length;
        }
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
