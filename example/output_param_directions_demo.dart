// Demonstrates `ParamDirection` + `DirectedParam` for API contracts.
// Native `OUTPUT` / `INOUT` binding is not wired yet — use
// `ParamDirection.input` or return data via `SELECT`/`OUTPUT` clauses
// that project into the result set instead of bound output parameters.
//
// See: doc/notes/TYPE_MAPPING.md §3.1, doc/Features/PENDING_IMPLEMENTATIONS.md §3.

import 'dart:io' show stdout;

import 'package:odbc_fast/odbc_fast.dart';

void main() {
  final inOnly = paramValuesFromDirected([
    const DirectedParam(value: 42),
    DirectedParam(
      value: 'hi',
      type: SqlDataType.nVarChar(length: 40),
    ),
  ]);
  stdout.writeln('Input-only params serialised: ${inOnly.length}');

  try {
    paramValuesFromDirected([
      const DirectedParam(
        value: 0,
        direction: ParamDirection.output,
      ),
    ]);
  } on Object catch (e) {
    if (e is UnsupportedError) {
      stdout.writeln('Expected for OUTPUT today: ${e.message}');
    } else {
      rethrow;
    }
  }
}
