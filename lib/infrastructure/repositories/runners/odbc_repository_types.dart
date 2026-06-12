import 'package:odbc_fast/domain/entities/odbc_event.dart';
import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:result_dart/result_dart.dart';

/// Shared typedefs and constants for repository runners.

typedef NativeIdLookupFn = int? Function(String connectionId);

typedef EmitEventFn = void Function(OdbcEvent event);

typedef StreamNativeQueryFn = Stream<ParsedRowBuffer> Function(
  int nativeId,
  String sql, {
  int? maxBufferBytes,
});

typedef StreamingFailureFn = Future<Failure<QueryResult, OdbcError>> Function(
  Exception error,
);

typedef OdbcErrorFactoryFn = OdbcError Function({
  required String message,
  String? sqlState,
  int? nativeCode,
});

/// Message used when a query times out (see `ConnectionOptions.queryTimeout`).
const odbcQueryTimedOutMessage = 'Query timed out';

const odbcStreamProtocolErrorPrefix = 'Streaming protocol error';
const odbcStreamInterruptedPrefix = 'Streaming interrupted';
const odbcUnsupportedCancelSqlState = '0A000';
const odbcUnsupportedCancelNativeCode = 5001;

OdbcError odbcQueryErrorFactory({
  required String message,
  String? sqlState,
  int? nativeCode,
}) =>
    QueryError(message: message, sqlState: sqlState, nativeCode: nativeCode);

OdbcError odbcConnectionErrorFactory({
  required String message,
  String? sqlState,
  int? nativeCode,
}) =>
    ConnectionError(
      message: message,
      sqlState: sqlState,
      nativeCode: nativeCode,
    );

bool isUnsupportedCancellation({
  required String message,
  required String? sqlState,
  required int? nativeCode,
}) {
  final normalizedSqlState = (sqlState ?? '').replaceAll('\x00', '').trim();
  if (normalizedSqlState == odbcUnsupportedCancelSqlState ||
      nativeCode == odbcUnsupportedCancelNativeCode) {
    return true;
  }
  final lower = message.toLowerCase();
  return lower.contains('unsupported feature') &&
      lower.contains('statement cancellation');
}
