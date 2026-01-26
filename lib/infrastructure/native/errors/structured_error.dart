import 'dart:convert';
import 'dart:typed_data';

class StructuredError {

  const StructuredError({
    required this.sqlState,
    required this.nativeCode,
    required this.message,
  });
  final List<int> sqlState;
  final int nativeCode;
  final String message;

  String get sqlStateString {
    return String.fromCharCodes(sqlState);
  }

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
