import 'dart:convert';
import 'dart:typed_data';

const int _tagNull = 0;
const int _tagString = 1;
const int _tagInteger = 2;
const int _tagBigInt = 3;
const int _tagDecimal = 4;
const int _tagBinary = 5;
const Endian _littleEndian = Endian.little;
const int _defaultDecimalScale = 6;
const int _minDateTimeYear = 1;
const int _maxDateTimeYear = 9999;

List<int> _u32Le(int v) {
  final buffer = Uint8List(4);
  final byteData = ByteData.view(buffer.buffer);
  byteData.setUint32(0, v, _littleEndian);
  return buffer;
}

List<int> _i32Le(int v) {
  final buffer = Uint8List(4);
  final byteData = ByteData.view(buffer.buffer);
  byteData.setInt32(0, v, _littleEndian);
  return buffer;
}

List<int> _i64Le(int v) {
  final buffer = Uint8List(8);
  final byteData = ByteData.view(buffer.buffer);
  byteData.setInt64(0, v, _littleEndian);
  return buffer;
}

String _toValidatedUtcIso8601(DateTime value) {
  if (value.year < _minDateTimeYear || value.year > _maxDateTimeYear) {
    throw ArgumentError(
      'DateTime year must be between $_minDateTimeYear and '
      '$_maxDateTimeYear, got ${value.year}.',
    );
  }
  return value.toUtc().toIso8601String();
}

String _unsupportedParameterTypeMessage(Object value) {
  final buffer = StringBuffer()
    ..write('Unsupported parameter type: ')
    ..write(value.runtimeType)
    ..write('. ')
    ..write(
      'Expected one of: null, int, String, List<int>, bool, double, '
      'DateTime, or ParamValue. ',
    )
    ..write('Use explicit ParamValue wrapper if needed, e.g., ')
    ..write('ParamValueString(value) for custom string conversion.');
  return buffer.toString();
}

/// Explicit SQL data types for optional typed parameter API.
///
/// This is an experimental, non-breaking layer on top of [ParamValue].
/// Existing untyped conversions continue to work as before.
class SqlDataType {
  const SqlDataType._(this.kind, {this.length, this.precision, this.scale});

  /// Semantic SQL kind used for validation and conversion.
  final String kind;

  /// Optional length for textual/binary kinds.
  final int? length;

  /// Optional precision for decimal kinds.
  final int? precision;

  /// Optional scale for decimal kinds.
  final int? scale;

  static const SqlDataType int32 = SqlDataType._('int32');
  static const SqlDataType int64 = SqlDataType._('int64');
  static const SqlDataType dateTime = SqlDataType._('datetime');
  static const SqlDataType date = SqlDataType._('date');
  static const SqlDataType time = SqlDataType._('time');
  static const SqlDataType boolAsInt32 = SqlDataType._('bool_as_int32');

  static SqlDataType decimal({int? precision, int? scale}) =>
      SqlDataType._('decimal', precision: precision, scale: scale);

  static SqlDataType varChar({int? length}) =>
      SqlDataType._('varchar', length: length);

  static SqlDataType nVarChar({int? length}) =>
      SqlDataType._('nvarchar', length: length);

  static SqlDataType varBinary({int? length}) =>
      SqlDataType._('varbinary', length: length);
}

/// Explicitly typed parameter value.
///
/// Use this wrapper when caller wants to opt into explicit SQL typing while
/// preserving compatibility with the existing `List<dynamic>` API.
class SqlTypedValue {
  const SqlTypedValue({
    required this.type,
    required this.value,
  });

  final SqlDataType type;
  final Object? value;
}

/// Convenience helper to create [SqlTypedValue] instances.
SqlTypedValue typedParam(SqlDataType type, Object? value) {
  return SqlTypedValue(type: type, value: value);
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

/// Converts a single object to a `ParamValue` instance.
///
/// Supported implicit input types:
/// - `null` → `ParamValueNull`
/// - `ParamValue` → returned as-is
/// - `int` → `ParamValueInt32` or `ParamValueInt64` (based on range)
/// - `String` → `ParamValueString`
/// - `List<int>` or `Uint8List` → `ParamValueBinary`
/// - `bool` → `ParamValueInt32(1|0)` (canonical mapping)
/// - `double` → `ParamValueDecimal(value.toStringAsFixed(6))`
///   (canonical mapping; `NaN/Infinity` rejected)
/// - `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`
///   (canonical mapping; year must be in `[1, 9999]`)
///
/// Throws [ArgumentError] for unsupported types with actionable message.
///
/// Example:
/// ```dart
/// final pv = toParamValue(42); // ParamValueInt32(42)
/// final pvNull = toParamValue(null); // ParamValueNull
/// final pvBool = toParamValue(true); // ParamValueInt32(1)
/// ```
ParamValue toParamValue(Object? value) {
  if (value == null) return const ParamValueNull();
  if (value is ParamValue) return value;
  if (value is SqlTypedValue) return _toTypedParamValue(value);

  // Fast path for int - most common case
  if (value is int) {
    if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
      return ParamValueInt32(value);
    }
    return ParamValueInt64(value);
  }

  // String - common case
  if (value is String) return ParamValueString(value);

  // Binary data
  if (value is List<int>) return ParamValueBinary(value);

  // Canonical mappings - explicit conversions with clear semantics
  if (value is bool) {
    return ParamValueInt32(value ? 1 : 0);
  }
  if (value is double) {
    if (value.isNaN) {
      throw ArgumentError(
        'Double value is NaN. Cannot convert to decimal. '
        'Use explicit ParamValue with desired representation.',
      );
    }
    if (value.isInfinite) {
      final label = value.isNegative ? '-Infinity' : 'Infinity';
      throw ArgumentError(
        'Double value is $label. Cannot convert to decimal. '
        'Use explicit ParamValue with desired representation.',
      );
    }
    return ParamValueDecimal(value.toStringAsFixed(_defaultDecimalScale));
  }
  if (value is DateTime) {
    return ParamValueString(_toValidatedUtcIso8601(value));
  }

  // Unsupported type - explicit error instead of silent toString() fallback
  throw ArgumentError(_unsupportedParameterTypeMessage(value));
}

ParamValue _toTypedParamValue(SqlTypedValue typedValue) {
  final type = typedValue.type;
  final value = typedValue.value;

  if (value == null) {
    return const ParamValueNull();
  }

  switch (type.kind) {
    case 'int32':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.int32 expects int, got ${value.runtimeType}',
        );
      }
      if (value < -0x80000000 || value > 0x7FFFFFFF) {
        throw ArgumentError(
          'SqlDataType.int32 value out of range: $value',
        );
      }
      return ParamValueInt32(value);
    case 'int64':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.int64 expects int, got ${value.runtimeType}',
        );
      }
      return ParamValueInt64(value);
    case 'decimal':
      if (value is num) {
        return ParamValueDecimal(value.toString());
      }
      if (value is String) {
        return ParamValueDecimal(value);
      }
      throw ArgumentError(
        'SqlDataType.decimal expects num or String, got ${value.runtimeType}',
      );
    case 'varchar':
    case 'nvarchar':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'varbinary':
      if (value is! List<int>) {
        throw ArgumentError(
          'SqlDataType.varBinary expects List<int>, got ${value.runtimeType}',
        );
      }
      return ParamValueBinary(value);
    case 'datetime':
      if (value is DateTime) {
        return ParamValueString(_toValidatedUtcIso8601(value));
      }
      if (value is String) {
        return ParamValueString(value);
      }
      throw ArgumentError(
        'SqlDataType.dateTime expects DateTime or String, '
        'got ${value.runtimeType}',
      );
    case 'date':
    case 'time':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'bool_as_int32':
      if (value is! bool) {
        throw ArgumentError(
          'SqlDataType.boolAsInt32 expects bool, got ${value.runtimeType}',
        );
      }
      return ParamValueInt32(value ? 1 : 0);
  }

  throw ArgumentError('Unsupported SqlDataType kind: ${type.kind}');
}

/// Converts a list of objects to `ParamValue` instances.
///
/// Fast path: if all items are already `ParamValue` or `null`,
/// converts and returns efficiently.
///
/// Supported implicit input types:
/// - `null` → `ParamValueNull`
/// - `ParamValue` → returned as-is (fast path)
/// - `int` → `ParamValueInt32` or `ParamValueInt64` (based on range)
/// - `String` → `ParamValueString`
/// - `List<int>` → `ParamValueBinary`
/// - `bool` → `ParamValueInt32(1|0)` (canonical mapping)
/// - `double` → `ParamValueDecimal(value.toStringAsFixed(6))`
///   (canonical mapping; `NaN/Infinity` rejected)
/// - `DateTime` → `ParamValueString(value.toUtc().toIso8601String())`
///   (canonical mapping; year must be in `[1, 9999]`)
///
/// Throws [ArgumentError] for unsupported types with actionable message.
///
/// Example:
/// ```dart
/// final params = paramValuesFromObjects([1, 'hello', null]);
/// // Returns: [ParamValueInt32(1), ParamValueString('hello'), ParamValueNull()]
/// ```
List<ParamValue> paramValuesFromObjects(List<Object?> params) {
  // Fast path: check if all items are already ParamValue or null
  if (params.isNotEmpty) {
    var allParamValueOrNull = true;
    for (final item in params) {
      if (item != null && item is! ParamValue) {
        allParamValueOrNull = false;
        break;
      }
    }
    if (allParamValueOrNull) {
      // Fast path: convert nulls to ParamValueNull, skip other items
      final result =
          List<ParamValue>.filled(params.length, const ParamValueNull());
      for (var i = 0; i < params.length; i++) {
        final item = params[i];
        if (item is ParamValue) {
          result[i] = item;
        }
      }
      return result;
    }
  }

  // Pre-size output list for better performance
  final result = List<ParamValue>.filled(params.length, const ParamValueNull());

  for (var i = 0; i < params.length; i++) {
    result[i] = toParamValue(params[i]);
  }

  return result;
}
