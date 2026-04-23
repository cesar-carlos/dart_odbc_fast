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

/// Converts [DirectedParam] rows to the binary [ParamValue] list used by
/// the engine. [ParamDirection.input] only — any other direction throws
/// [UnsupportedError] until the native pipeline binds `OUT` / `INOUT`
/// (see `doc/Features/PENDING_IMPLEMENTATIONS.md` §3).
List<ParamValue> paramValuesFromDirected(List<DirectedParam> params) {
  return params.map((d) {
    if (d.direction != ParamDirection.input) {
      throw UnsupportedError(
        'ParamDirection.${d.direction.name} is not supported by the engine '
        'yet; use ParamDirection.input only, or restructure the SQL to '
        'return values via a result set.',
      );
    }
    if (d.type == null) {
      return toParamValue(d.value);
    }
    return toParamValue(typedParam(d.type!, d.value));
  }).toList();
}
