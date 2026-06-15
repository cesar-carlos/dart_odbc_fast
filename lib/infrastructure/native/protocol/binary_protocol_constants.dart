import 'package:odbc_fast/domain/entities/param_value.dart' show ParamValue;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart'
    show ParamValue;
import 'package:odbc_fast/odbc_fast.dart' show ParamValue;

/// Wire-format constants shared by row-major, columnar, and trailer parsers.
abstract final class BinaryProtocolConstants {
  static const int magic = 0x4F444243;

  /// Trailer magic for [ParamValue] output slots (`b"OUT1"`).
  static const int outputFooterMagic = 0x3154554F;

  /// Trailer for materialized ref-cursor result sets (`b"RC1\0"`).
  static const int refCursorFooterMagic = 0x00314352;

  static const int protocolVersionRowMajor = 1;
  static const int protocolVersionColumnarV2 = 2;

  static const int headerSizeV1 = 16;
  static const int headerSizeColumnarV2 = 19;

  /// Size of the protocol header in bytes (v1 — kept for legacy call sites).
  static const int headerSize = headerSizeV1;
}
