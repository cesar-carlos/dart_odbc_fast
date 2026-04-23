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
