import 'dart:convert';
import 'dart:typed_data';

/// Represents a structured ODBC error from the native layer.
///
/// Contains SQLSTATE code, native error code, and error message.
/// This provides more detailed error information than simple error strings.
class StructuredError {
  /// Creates a new [StructuredError] instance.
  ///
  /// The [sqlState] is a 5-byte list representing the SQLSTATE code.
  /// The [nativeCode] is the database-specific native error code.
  /// The [message] is the human-readable error message.
  const StructuredError({
    required this.sqlState,
    required this.nativeCode,
    required this.message,
  });

  /// SQLSTATE code as a 5-byte list (e.g., [0x34, 0x32, 0x53, 0x30, 0x32]).
  final List<int> sqlState;

  /// Native database error code.
  final int nativeCode;

  /// Human-readable error message.
  final String message;

  /// Gets the SQLSTATE code as a string.
  ///
  /// Converts the byte list to a 5-character string (e.g., '42S02').
  String get sqlStateString {
    return String.fromCharCodes(sqlState);
  }

  /// Deserializes a [StructuredError] from binary data.
  ///
  /// The [data] must contain at least 13 bytes: 5 bytes for SQLSTATE,
  /// 4 bytes for native code, 4 bytes for message length, followed by
  /// the UTF-8 encoded message.
  ///
  /// Returns null if the data is invalid or too short.
  static StructuredError? deserialize(List<int> data) {
    if (data.length < 13) {
      return null;
    }

    final sqlState = data.sublist(0, 5);

    final byteData = ByteData.sublistView(Uint8List.fromList(data));
    final nativeCode = byteData.getInt32(5, Endian.little);
    final msgLen = byteData.getUint32(9, Endian.little);

    if (data.length < 13 + msgLen) {
      return null;
    }

    final message = utf8.decode(data.sublist(13, 13 + msgLen));

    return StructuredError(
      sqlState: sqlState,
      nativeCode: nativeCode,
      message: message,
    );
  }
}
