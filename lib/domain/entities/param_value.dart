import 'dart:convert';
import 'dart:typed_data';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;
const int _tagRefCursorOut = 6;
const Endian _littleEndian = Endian.little;

List<int> _u32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setUint32(0, v, _littleEndian);
  return buffer;
}

List<int> _i32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setInt32(0, v, _littleEndian);
  return buffer;
}

List<int> _i64Le(int v) {
  final buffer = Uint8List(8);
  ByteData.view(buffer.buffer).setInt64(0, v, _littleEndian);
  return buffer;
}

/// Explicitly typed ODBC parameter value for prepared and positional queries.
///
/// Use this wrapper when callers want explicit SQL typing while preserving
/// compatibility with the legacy `List<dynamic>` parameter API.
sealed class ParamValue {
  /// Creates a new [ParamValue] instance.
  const ParamValue();

  /// Serializes this parameter value to the legacy v0 wire format.
  List<int> serialize();
}

/// Represents a NULL parameter value.
class ParamValueNull extends ParamValue {
  /// Creates a new [ParamValueNull] instance.
  const ParamValueNull();

  @override
  List<int> serialize() => [_tagNull, ..._u32Le(0)];
}

/// Represents a string parameter value.
class ParamValueString extends ParamValue {
  /// Creates a new [ParamValueString] instance.
  const ParamValueString(this.value);

  /// The string value.
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagString, ..._u32Le(b.length), ...b];
  }
}

/// Represents a 32-bit integer parameter value.
class ParamValueInt32 extends ParamValue {
  /// Creates a new [ParamValueInt32] instance.
  const ParamValueInt32(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagInteger, ..._u32Le(4), ..._i32Le(value)];
}

/// Represents a 64-bit integer parameter value.
class ParamValueInt64 extends ParamValue {
  /// Creates a new [ParamValueInt64] instance.
  const ParamValueInt64(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagBigInt, ..._u32Le(8), ..._i64Le(value)];
}

/// Represents a decimal/numeric parameter value as a string.
class ParamValueDecimal extends ParamValue {
  /// Creates a new [ParamValueDecimal] instance.
  const ParamValueDecimal(this.value);

  /// The decimal value as a string.
  final String value;

  @override
  List<int> serialize() {
    final b = utf8.encode(value);
    return [_tagDecimal, ..._u32Le(b.length), ...b];
  }
}

/// Represents a binary parameter value.
class ParamValueBinary extends ParamValue {
  /// Creates a new [ParamValueBinary] instance.
  const ParamValueBinary(this.value);

  /// The binary data.
  final List<int> value;

  @override
  List<int> serialize() => [_tagBinary, ..._u32Le(value.length), ...value];
}

/// Placeholder for Oracle `SYS_REFCURSOR` (and similar) `OUT` parameters on
/// the DRT1 wire.
class ParamValueRefCursorOut extends ParamValue {
  /// Creates a [ParamValueRefCursorOut] instance.
  const ParamValueRefCursorOut();

  @override
  List<int> serialize() => [_tagRefCursorOut, ..._u32Le(0)];
}
