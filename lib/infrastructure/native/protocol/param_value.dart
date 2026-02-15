import 'dart:convert';
import 'dart:typed_data';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;

List<int> _u32Le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i32Le(int v) {
  final b = ByteData(4)..setInt32(0, v, Endian.little);
  return b.buffer.asUint8List(0, 4).toList();
}

List<int> _i64Le(int v) {
  final b = ByteData(8)..setInt64(0, v, Endian.little);
  return b.buffer.asUint8List(0, 8).toList();
}

/// Base class for parameter values in prepared statements.
///
/// All parameter values must extend this sealed class and implement
/// [serialize] to convert the value to binary format.
sealed class ParamValue {
  /// Creates a new [ParamValue] instance.
  const ParamValue();

  /// Serializes this parameter value to binary format.
  ///
  /// Returns a list of bytes representing the parameter value.
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
  ///
  /// The [value] is the string to use as the parameter value.
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
  ///
  /// The [value] is the 32-bit integer to use as the parameter value.
  const ParamValueInt32(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagInteger, ..._u32Le(4), ..._i32Le(value)];
}

/// Represents a 64-bit integer parameter value.
class ParamValueInt64 extends ParamValue {
  /// Creates a new [ParamValueInt64] instance.
  ///
  /// The [value] is the 64-bit integer to use as the parameter value.
  const ParamValueInt64(this.value);

  /// The integer value.
  final int value;

  @override
  List<int> serialize() => [_tagBigInt, ..._u32Le(8), ..._i64Le(value)];
}

/// Represents a decimal/numeric parameter value as a string.
class ParamValueDecimal extends ParamValue {
  /// Creates a new [ParamValueDecimal] instance.
  ///
  /// The [value] is the decimal value as a string (e.g., '123.45').
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
  ///
  /// The [value] is the binary data as a list of bytes.
  const ParamValueBinary(this.value);

  /// The binary data.
  final List<int> value;

  @override
  List<int> serialize() => [_tagBinary, ..._u32Le(value.length), ...value];
}

/// Serializes a list of parameter values to binary format.
///
/// The [params] list should contain [ParamValue] instances in the order
/// they appear in the prepared statement.
///
/// Returns a [Uint8List] containing the serialized parameters.
Uint8List serializeParams(List<ParamValue> params) {
  final out = <int>[];
  for (final p in params) {
    out.addAll(p.serialize());
  }
  return Uint8List.fromList(out);
}

/// Converts a list of objects to `ParamValue` instances.
///
/// Supports null, int, String, `List<int>`, and `ParamValue`.
/// Other types are converted to string.
List<ParamValue> paramValuesFromObjects(List<Object?> params) {
  return params.map((Object? o) {
    if (o == null) return const ParamValueNull();
    if (o is ParamValue) return o;
    if (o is int) {
      if (o >= -0x80000000 && o <= 0x7FFFFFFF) {
        return ParamValueInt32(o);
      }
      return ParamValueInt64(o);
    }
    if (o is String) return ParamValueString(o);
    if (o is List<int>) return ParamValueBinary(o);
    return ParamValueString(o.toString());
  }).toList();
}
