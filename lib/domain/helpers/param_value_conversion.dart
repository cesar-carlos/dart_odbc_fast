import 'package:odbc_fast/domain/entities/param_value.dart';

const int _defaultDecimalScale = 6;
const int _minDateTimeYear = 1;
const int _maxDateTimeYear = 9999;

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
  return 'Unsupported parameter type: ${value.runtimeType}. '
      'Expected one of: null, int, String, List<int>, bool, double, '
      'DateTime, or ParamValue. '
      'Use explicit ParamValue wrapper if needed, e.g., '
      'ParamValueString(value) for custom string conversion.';
}

/// Converts a single object to a [ParamValue] instance.
///
/// Handles the common implicit Dart types. For `SqlDataType` / `typedParam`
/// mappings, use the infrastructure protocol helpers (also re-exported from
/// `package:odbc_fast/odbc_fast.dart`).
ParamValue toParamValue(Object? value) {
  if (value == null) return const ParamValueNull();
  if (value is ParamValue) return value;

  if (value is int) {
    if (value >= -0x80000000 && value <= 0x7FFFFFFF) {
      return ParamValueInt32(value);
    }
    return ParamValueInt64(value);
  }

  if (value is String) return ParamValueString(value);
  if (value is List<int>) return ParamValueBinary(value);

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

  throw ArgumentError(_unsupportedParameterTypeMessage(value));
}

/// Converts plain Dart objects to [ParamValue] wire tags.
///
/// Converts plain Dart objects to [ParamValue] wire tags. Pair with
/// `executeQueryParamValuesFromObjects` and related `…FromObjects` extension
/// methods on `IOdbcRepository`.
List<ParamValue> paramValuesFromObjects(List<Object?> params) {
  if (params.isEmpty) return const [];

  if (params.isNotEmpty) {
    var allParamValueOrNull = true;
    for (final item in params) {
      if (item != null && item is! ParamValue) {
        allParamValueOrNull = false;
        break;
      }
    }
    if (allParamValueOrNull) {
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

  final result = List<ParamValue>.filled(params.length, const ParamValueNull());
  for (var i = 0; i < params.length; i++) {
    result[i] = toParamValue(params[i]);
  }
  return result;
}
