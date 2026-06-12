import 'package:odbc_fast/domain/types/param_direction.dart';
import 'package:odbc_fast/domain/types/sql_data_type.dart';

/// A parameter with an explicit [ParamDirection] for the DRT1 wire path.
///
/// Native support covers scalar/text `OUT` / `INOUT`, `OUT1` result trailers,
/// and Oracle ref-cursor output parameters. Binary `OUT` / `INOUT`, TVP, and
/// the exhaustive `SqlDataType` x direction matrix remain product-gated.
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
