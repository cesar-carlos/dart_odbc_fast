part of 'param_value.dart';

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
    case 'smallint':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.smallInt expects int, got ${value.runtimeType}',
        );
      }
      if (value < _smallIntMin || value > _smallIntMax) {
        throw ArgumentError(
          'SqlDataType.smallInt value out of range '
          '[$_smallIntMin, $_smallIntMax]: $value',
        );
      }
      return ParamValueInt32(value);
    case 'bigint':
      // Idiomatic alias for int64 — same wire representation. We
      // intentionally accept any int (Dart ints are 64-bit on every
      // supported platform) instead of duplicating int64's range
      // check, which is a no-op there.
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.bigInt expects int, got ${value.runtimeType}',
        );
      }
      return ParamValueInt64(value);
    case 'json':
      return ParamValueString(_toJsonString(value, validate: false));
    case 'json_validated':
      return ParamValueString(_toJsonString(value, validate: true));
    case 'uuid':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.uuid expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(_normaliseUuid(value));
    case 'money':
      return ParamValueDecimal(_toMoneyString(value));
    case 'tinyint':
      if (value is! int) {
        throw ArgumentError(
          'SqlDataType.tinyInt expects int, got ${value.runtimeType}',
        );
      }
      if (value < _tinyIntMin || value > _tinyIntMax) {
        throw ArgumentError(
          'SqlDataType.tinyInt value out of range '
          '[$_tinyIntMin, $_tinyIntMax]: $value',
        );
      }
      return ParamValueInt32(value);
    case 'bit':
      if (value is bool) {
        return ParamValueInt32(value ? 1 : 0);
      }
      if (value is int) {
        if (value != 0 && value != 1) {
          throw ArgumentError(
            'SqlDataType.bit expects exactly 0 or 1 when given an int; '
            'got $value',
          );
        }
        return ParamValueInt32(value);
      }
      throw ArgumentError(
        'SqlDataType.bit expects bool or int (0 or 1), '
        'got ${value.runtimeType}',
      );
    case 'text':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.text expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'xml':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.xml expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'xml_validated':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.xml expects String, got ${value.runtimeType}',
        );
      }
      _validateXmlShape(value);
      return ParamValueString(value);
    case 'interval':
      return ParamValueString(_toIntervalString(value));
    case 'range':
    case 'tsvector':
    case 'bfile':
      // Three engine-specific kinds with no per-input validation:
      // the server is the authoritative validator at execute-time.
      // Sharing one branch keeps the switch tight.
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String, got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'cidr':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.cidr expects String, got ${value.runtimeType}',
        );
      }
      _validateCidrLiteral(value);
      return ParamValueString(value);
    case 'hierarchyid':
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.hierarchyId expects String, got ${value.runtimeType}',
        );
      }
      _validateHierarchyIdLiteral(value);
      return ParamValueString(value);
    case 'geography':
    case 'geometry':
      // We only accept WKT here (String). Binary WKB callers should
      // use SqlDataType.varBinary together with `*::STGeomFromWKB`.
      // Rejecting `List<int>` explicitly avoids silent ambiguity.
      if (value is! String) {
        throw ArgumentError(
          'SqlDataType.${type.kind} expects String (WKT); for binary WKB use '
          'SqlDataType.varBinary with STGeomFromWKB. '
          'Got ${value.runtimeType}',
        );
      }
      return ParamValueString(value);
    case 'interval_year_to_month':
      return ParamValueString(_toIntervalYearToMonthString(value));
    case 'raw':
      if (value is! List<int>) {
        throw ArgumentError(
          'SqlDataType.raw expects List<int>, got ${value.runtimeType}',
        );
      }
      return ParamValueBinary(value);
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
