/// Declares how a parameter is bound to a statement. Used by
/// `DirectedParam` for API contracts that will align with future
/// native OUTPUT / `INOUT` / `REF CURSOR` work (see
/// `doc/notes/TYPE_MAPPING.md`).
enum ParamDirection {
  /// `INPUT` (default) — value is sent to the server only.
  input,

  /// `OUTPUT` — placeholder filled by the server after execution.
  output,

  /// `INOUT` — value is sent and may be updated by the server.
  inOut,
}
