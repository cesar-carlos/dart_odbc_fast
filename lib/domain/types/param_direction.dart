/// Declares how a directed DRT1 parameter is bound to a statement.
///
/// Native support covers scalar/text `OUTPUT` / `INOUT` and the Oracle
/// `REF CURSOR` marker; driver-specific limits are documented in
/// `doc/notes/TYPE_MAPPING.md`.
enum ParamDirection {
  /// `INPUT` (default) — value is sent to the server only.
  input,

  /// `OUTPUT` — placeholder filled by the server after execution.
  output,

  /// `INOUT` — value is sent and may be updated by the server.
  inOut,
}
