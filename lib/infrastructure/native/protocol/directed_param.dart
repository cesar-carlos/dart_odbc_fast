import 'dart:typed_data';

import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';

/// A parameter with an explicit [ParamDirection] for API surfaces that
/// prepare the contract for `OUTPUT` / `INOUT` (native engine support is
/// still being rolled in — see `doc/notes/TYPE_MAPPING.md` §3.1).
///
/// When [direction] is [ParamDirection.input] and [type] is null, the
/// payload serialises the same as an untyped value.
class DirectedParam {
  const DirectedParam({
    required this.value,
    this.type,
    this.direction = ParamDirection.input,
  });

  final Object? value;
  final SqlDataType? type;
  final ParamDirection direction;
}

/// Little-endian DRT1 magic (Rust: `odbc_engine` crate `bound_param` module).
const List<int> drt1MagicBytes = [0x44, 0x52, 0x54, 0x31];

/// Stable error prefix, aligned with `output_aware_params` / native
/// `ValidationError` (TYPE_MAPPING §3.1).
const String kDirectedParamErrorPrefix = 'DIRECTED_PARAM|';

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
        '${kDirectedParamErrorPrefix}ref_cursor_out_invalid_direction: '
        'ParamValueRefCursorOut is only valid for ParamDirection.output',
      );
    }
    return;
  }
  if (pv is ParamValueBinary) {
    throw ArgumentError.value(
      pv,
      'value',
      '${kDirectedParamErrorPrefix}binary_out_inout_not_implemented: '
      'OUT/INOUT for binary columns is not implemented; use Integer, '
      'BigInt, String, or Decimal (see TYPE_MAPPING §3.1)',
    );
  }
  if (pv is ParamValueNull) {
    if (direction == ParamDirection.inOut) {
      throw ArgumentError.value(
        pv,
        'value',
        '${kDirectedParamErrorPrefix}inout_null: INOUT with ParamValueNull '
        'is not supported; pass Integer, BigInt, String, or non-empty '
        'Decimal',
      );
    }
    return;
  }
  if (pv is ParamValueDecimal) {
    if (pv.value.isEmpty) {
      throw ArgumentError.value(
        pv,
        'value',
        '${kDirectedParamErrorPrefix}decimal_inout_out_requires_non_empty: '
        'use a non-empty ParamValue::Decimal for OUT/INOUT or use String',
      );
    }
  }
}

List<int> _u32Le(int v) {
  final buffer = Uint8List(4);
  ByteData.view(buffer.buffer).setUint32(0, v, Endian.little);
  return buffer;
}

/// Serialises [DirectedParam] values to a **DRT1** buffer: `DRT1` + u32 count
/// and repeated `(u8 direction)(ParamValue wire)`. Prefer
/// `IOdbcService.executeQueryDirectedParams` or
/// `IOdbcRepository.executeQueryParamBuffer` with this buffer. Engine mapping:
/// [ParamDirection] `input` = 0, `output` = 1, `inOut` = 2.
Uint8List serializeDirectedParams(List<DirectedParam> params) {
  final out = BytesBuilder()
    ..add(drt1MagicBytes)
    ..add(_u32Le(params.length));
  for (final d in params) {
    out.addByte(d.direction.index);
    final pv = d.type == null
        ? toParamValue(d.value)
        : toParamValue(typedParam(d.type!, d.value));
    validateDirectedOutInOut(d.direction, pv);
    out.add(pv.serialize());
  }
  return out.toBytes();
}

/// Converts [DirectedParam] rows to a legacy **v0** binary [ParamValue] list
/// (concatenated tags, all treated as `INPUT` on the wire).
///
/// [ParamDirection.input] only — any other direction throws
/// [UnsupportedError] because the legacy path cannot represent direction
/// (use [serializeDirectedParams] and the service
/// `executeQueryDirectedParams` for `OUT` / `INOUT`).
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
