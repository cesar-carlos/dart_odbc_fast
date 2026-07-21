import 'dart:async';
import 'dart:typed_data';

import 'package:odbc_fast/domain/entities/query_result.dart' show QueryResult;
import 'package:odbc_fast/domain/entities/result_encoding.dart';
import 'package:odbc_fast/domain/errors/odbc_error.dart';
import 'package:odbc_fast/domain/helpers/typed_columnar_converter.dart';
import 'package:odbc_fast/infrastructure/native/protocol/binary_protocol.dart'
    show ParsedRowBuffer;
import 'package:odbc_fast/infrastructure/native/protocol/named_parameter_parser.dart'
    show NamedParameterParser, ParameterMissingException;
import 'package:odbc_fast/infrastructure/native/protocol/param_value.dart';
import 'package:odbc_fast/infrastructure/repositories/repository_state.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_query_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_repository_types.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/odbc_result_parser.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/query_timeout_helpers.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_columnar_runner.dart';
import 'package:odbc_fast/infrastructure/repositories/runners/stream_error_mapper.dart';
import 'package:result_dart/result_dart.dart';

/// Row-major and unified `streamQuery` streaming operations.
class StreamQueryRunner {
  StreamQueryRunner({
    required this.ffi,
    required this.state,
    required this.parser,
    required this.query,
    required StreamColumnarRunner columnar,
    required StreamErrorMapper errors,
  })  : _columnar = columnar,
        _errors = errors;

  final OdbcFfiDispatch ffi;
  final OdbcRepositoryState state;
  final OdbcResultParser parser;
  final OdbcQueryRunner query;
  final StreamColumnarRunner _columnar;
  final StreamErrorMapper _errors;

  Stream<Result<QueryResult>> streamQuery(
    String connectionId,
    String sql,
  ) async* {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final queryTimeout = opts?.queryTimeout;
    final lazyStrings = opts?.lazyStrings ?? false;
    final encoding = state.defaultResultEncoding;

    Stream<Result<QueryResult>> createSource() async* {
      try {
        if (encoding.isColumnar) {
          await for (final chunk
              in _columnar.streamNativeColumnarQueryWithFallback(
            nativeId,
            sql,
            maxBufferBytes: maxBytes,
            lazyStrings: lazyStrings,
            resultEncoding: encoding,
          )) {
            yield Success(fromTypedColumnar(chunk));
          }
          return;
        }

        await for (final chunk in streamNativeQueryWithFallback(
          nativeId,
          sql,
          maxBufferBytes: maxBytes,
          resultEncoding: encoding,
          lazyStrings: lazyStrings,
        )) {
          yield Success(parser.toQueryResult(chunk));
        }
      } on Exception catch (e) {
        yield await _errors.streamingFailureFromException(e);
      }
    }

    final source = createSource();

    yield* streamWithQueryTimeout(
      source: source,
      queryTimeout: queryTimeout,
      onTimeoutItem: const Failure<QueryResult, OdbcError>(
        QueryError(message: odbcQueryTimedOutMessage),
      ),
    );
  }

  Stream<Result<QueryResult>> streamQueryNamed(
    String connectionId,
    String sql,
    Map<String, Object?> namedParams,
  ) async* {
    final nativeId = state.connectionIds[connectionId];
    if (nativeId == null) {
      yield const Failure<QueryResult, OdbcError>(
        ValidationError(message: 'Invalid connection ID'),
      );
      return;
    }

    late final String cleanedSql;
    late final Uint8List paramsBuffer;
    try {
      final extract = NamedParameterParser.extract(sql);
      final positional = NamedParameterParser.toPositionalParams(
        namedParams: namedParams,
        paramNames: extract.paramNames,
      );
      cleanedSql = extract.cleanedSql;
      paramsBuffer = serializeParams(paramValuesFromObjects(positional));
    } on ParameterMissingException catch (e) {
      yield Failure<QueryResult, OdbcError>(
        ValidationError(message: e.message),
      );
      return;
    } on Exception catch (e) {
      yield Failure<QueryResult, OdbcError>(
        QueryError(message: e.toString()),
      );
      return;
    }

    final supportsParams =
        ffi.isAsync || ffi.sync.native.supportsStreamStartParams;
    if (!supportsParams) {
      yield await query.executeQueryNamed(connectionId, sql, namedParams);
      return;
    }

    final opts = state.optionsFor(connectionId);
    final maxBytes = opts?.maxResultBufferBytes;
    final queryTimeout = opts?.queryTimeout;
    final lazyStrings = opts?.lazyStrings ?? false;
    final encoding = state.defaultResultEncoding;

    Stream<Result<QueryResult>> createSource() async* {
      try {
        await for (final chunk in streamNativeQueryWithFallback(
          nativeId,
          cleanedSql,
          maxBufferBytes: maxBytes,
          resultEncoding: encoding,
          lazyStrings: lazyStrings,
          paramsBuffer: paramsBuffer,
        )) {
          yield Success(parser.toQueryResult(chunk));
        }
      } on Exception catch (e) {
        yield await _errors.streamingFailureFromException(e);
      }
    }

    yield* streamWithQueryTimeout(
      source: createSource(),
      queryTimeout: queryTimeout,
      onTimeoutItem: const Failure<QueryResult, OdbcError>(
        QueryError(message: odbcQueryTimedOutMessage),
      ),
    );
  }

  Stream<ParsedRowBuffer> streamNativeQueryWithFallback(
    int nativeId,
    String sql, {
    int? maxBufferBytes,
    ResultEncoding resultEncoding = ResultEncoding.rowMajor,
    bool lazyStrings = false,
    Uint8List? paramsBuffer,
  }) async* {
    final batched = ffi.isAsync
        ? ffi.async.streamQueryBatched(
            nativeId,
            sql,
            maxBufferBytes: maxBufferBytes,
            resultEncodingWire: resultEncoding.wireCode,
            lazyStrings: lazyStrings,
            paramsBuffer: paramsBuffer,
          )
        : ffi.sync.streamQueryBatched(
            nativeId,
            sql,
            resultEncoding: resultEncoding,
            lazyStrings: lazyStrings,
            paramsBuffer: paramsBuffer,
          );

    await for (final chunk in batched) {
      yield chunk;
    }
  }

  Future<Failure<QueryResult, OdbcError>> streamingFailureFromException(
    Exception error,
  ) =>
      _errors.streamingFailureFromException(error);
}
