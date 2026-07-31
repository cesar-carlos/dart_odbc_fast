import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/directed_param.dart';
import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

export 'package:odbc_fast/domain/entities/directed_param.dart';

/// Little-endian DRT1 magic (Rust: `odbc_engine` crate `bound_param` module).
const List<int> drt1MagicBytes = [0x44, 0x52, 0x54, 0x31];

/// Stable error prefix, aligned with `output_aware_params` / native
/// `ValidationError` (TYPE_MAPPING §3.1).
const String kDirectedParamErrorPrefix = 'DIRECTED_PARAM|';

const String _refCursorInvalidDirectionSlug =
    'ref_cursor_out_invalid_direction';
const String _binaryOutInOutNotImplementedSlug =
    'binary_out_inout_not_implemented';
const String _inOutNullSlug = 'inout_null';
const String _decimalOutInOutRequiresNonEmptySlug =
    'decimal_inout_out_requires_non_empty';

String _directedParamMessage(String slug, String detail) {
  return '$kDirectedParamErrorPrefix$slug: $detail';
}

/// Client-side checks for DRT1 `OUT` / `INOUT` that the native engine will
/// reject; fails fast with the same *slugs* as `output_aware_params.rs`.
void validateDirectedOutInOut(ParamDirection direction, ParamValue pv) {
  if (direction == ParamDirection.input) {
    return;
  }
  if (pv is ParamValueRefCursorOut) {
    if (direction != ParamDirection.output) {
      throw ArgumentError.value(
        pv,
        'value',
        _directedParamMessage(
          _refCursorInvalidDirectionSlug,
          'ParamValueRefCursorOut is only valid for ParamDirection.output',
        ),
      );
    }
    return;
  }
  if (pv is ParamValueBinary) {
    throw ArgumentError.value(
      pv,
      'value',
      _directedParamMessage(
        _binaryOutInOutNotImplementedSlug,
        'OUT/INOUT for binary columns is not implemented; use Integer, '
        'BigInt, String, or Decimal (see TYPE_MAPPING §3.1)',
      ),
    );
  }
  if (pv is ParamValueNull) {
    if (direction == ParamDirection.inOut) {
      throw ArgumentError.value(
        pv,
        'value',
        _directedParamMessage(
          _inOutNullSlug,
          'INOUT with ParamValueNull is not supported; pass Integer, BigInt, '
          'String, or non-empty Decimal',
        ),
      );
    }
    return;
  }
  if (pv is ParamValueDecimal) {
    if (pv.value.isEmpty) {
      throw ArgumentError.value(
        pv,
        'value',
        _directedParamMessage(
          _decimalOutInOutRequiresNonEmptySlug,
          'use a non-empty ParamValue::Decimal for OUT/INOUT or use String',
        ),
      );
    }
  }
}

/// Serialises [DirectedParam] values to a **DRT1** buffer.
Uint8List serializeDirectedParams(List<DirectedParam> params) {
  final directions = List<int>.filled(params.length, 0);
  final values = List<ParamValue>.filled(
    params.length,
    const ParamValueNull(),
  );
  for (var i = 0; i < params.length; i++) {
    final d = params[i];
    directions[i] = d.direction.index;
    final pv = d.type == null
        ? toParamValue(d.value)
        : toParamValue(typedParam(d.type!, d.value));
    validateDirectedOutInOut(d.direction, pv);
    values[i] = pv;
  }
  return serializeDirectedParamList(directions, values);
}

/// Converts [DirectedParam] rows to a legacy **v0** binary [ParamValue] list.
List<ParamValue> paramValuesFromDirected(List<DirectedParam> params) {
  return params.map((d) {
    if (d.direction != ParamDirection.input) {
      throw UnsupportedError(
        'ParamDirection.${d.direction.name} is not supported on the legacy '
        'parameter path; use serializeDirectedParams() and '
        'executeQueryDirectedParams() for OUT/INOUT.',
      );
    }
    if (d.type == null) {
      return toParamValue(d.value);
    }
    return toParamValue(typedParam(d.type!, d.value));
  }).toList();
}
