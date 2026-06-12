/// Explicit SQL data types for optional typed parameter API.
///
/// Domain contract for optional typed parameters. Wire serialization lives
/// in `infrastructure/native/protocol/param_value.dart`.
// ignore_for_file: comment_references
class SqlDataType {
  const SqlDataType._(this.kind, {this.length, this.precision, this.scale});

  factory SqlDataType.decimal({int? precision, int? scale}) =>
      SqlDataType._('decimal', precision: precision, scale: scale);

  factory SqlDataType.varChar({int? length}) =>
      SqlDataType._('varchar', length: length);

  factory SqlDataType.nVarChar({int? length}) =>
      SqlDataType._('nvarchar', length: length);

  factory SqlDataType.varBinary({int? length}) =>
      SqlDataType._('varbinary', length: length);

  /// SQL `JSON` / `JSONB` payload. Accepts a `String` (assumed to be
  /// already-serialised JSON), a `Map<String, dynamic>`, or a `List`;
  /// the latter two are encoded with `dart:convert::jsonEncode`.
  /// Serialised as a UTF-8 string on the wire (engines without a
  /// native `JSON` type accept this transparently as `NVARCHAR`).
  ///
  /// Pass `validate: true` to round-trip the input through `jsonDecode`
  /// before sending — useful in dev/test, off by default to avoid
  /// paying the parse cost on the hot path.
  factory SqlDataType.json({bool validate = false}) =>
      SqlDataType._(validate ? 'json_validated' : 'json');

  /// SQL `XML` — XML payload. Accepts a `String`. Serialised as a
  /// UTF-8 string on the wire (engines without a native `XML` type
  /// accept this transparently as `NVARCHAR`).
  ///
  /// Pass `validate: true` to run a *cheap structural sanity check*
  /// (must start with `<` and contain a matching `>` after trimming)
  /// before sending — useful for catching obvious mistakes early
  /// without paying the cost of a real XML parser. The default is
  /// `false` so multi-KB payloads don't pay the check on the hot
  /// path.
  factory SqlDataType.xml({bool validate = false}) =>
      SqlDataType._(validate ? 'xml_validated' : 'xml');

  /// Semantic SQL kind used for validation and conversion.
  final String kind;

  /// Optional length for textual/binary kinds.
  final int? length;

  /// Optional precision for decimal kinds.
  final int? precision;

  /// Optional scale for decimal kinds.
  final int? scale;

  static const SqlDataType int32 = SqlDataType._('int32');
  static const SqlDataType int64 = SqlDataType._('int64');
  static const SqlDataType dateTime = SqlDataType._('datetime');
  static const SqlDataType date = SqlDataType._('date');
  static const SqlDataType time = SqlDataType._('time');
  static const SqlDataType boolAsInt32 = SqlDataType._('bool_as_int32');

  /// SQL `SMALLINT` (16-bit signed). Validates the input against
  /// `[-32768, 32767]` and serialises as a 32-bit integer on the wire
  /// (the engine has no separate 16-bit slot in our binary protocol;
  /// the validation is what makes this type distinct from
  /// [SqlDataType.int32]).
  static const SqlDataType smallInt = SqlDataType._('smallint');

  /// SQL `BIGINT` (64-bit signed). Idiomatic alias for
  /// [SqlDataType.int64] — same wire representation, same validation,
  /// just the SQL-flavoured spelling so call sites read more naturally
  /// when paired with a `BIGINT` column.
  static const SqlDataType bigInt = SqlDataType._('bigint');

  /// SQL `UUID` / `UNIQUEIDENTIFIER`. Accepts the canonical
  /// `8-4-4-4-12` form, the bare 32-hex form, or either wrapped in
  /// `{...}`. Folds to lowercase canonical before sending so the
  /// engine sees a normalised value regardless of how the caller
  /// formatted it. Rejects anything that isn't a well-formed UUID
  /// with an actionable [ArgumentError].
  static const SqlDataType uuid = SqlDataType._('uuid');

  /// SQL `MONEY` / `SMALLMONEY` / `DECIMAL(15, 4)` — fixed monetary
  /// scale of 4 fractional digits. Accepts `num` (formatted with
  /// `toStringAsFixed(4)`) or `String` (passed through verbatim).
  /// `NaN` / `Infinity` are rejected. Use [SqlDataType.decimal] for
  /// arbitrary scale.
  static const SqlDataType money = SqlDataType._('money');

  /// SQL `TINYINT` (unsigned 8-bit on SQL Server / Sybase; the
  /// broadest interoperable contract). Validates the input against
  /// `[0, 255]` and serialises as a 32-bit integer on the wire (the
  /// engine has no separate 8-bit slot in our binary protocol; the
  /// validation is what makes this type distinct from
  /// [SqlDataType.int32]).
  ///
  /// MySQL/MariaDB callers using **signed** `TINYINT` (`[-128, 127]`)
  /// should use [SqlDataType.smallInt] instead — its `[-32768, 32767]`
  /// range comfortably covers the signed-tinyint domain without
  /// imposing an artificial restriction.
  static const SqlDataType tinyInt = SqlDataType._('tinyint');

  /// SQL `BIT` (boolean). Accepts `bool` (mapped to 1/0) or `int`
  /// (must be exactly 0 or 1). Serialises as a 32-bit integer on the
  /// wire — the canonical representation across SQL Server,
  /// PostgreSQL `BIT`, MySQL `BIT(1)`, Db2, Oracle (via
  /// `NUMBER(1)`).
  ///
  /// Idiomatic for columns whose *type name* is `BIT`. For columns
  /// labelled `BOOL` / `BOOLEAN` see [SqlDataType.boolAsInt32], which
  /// is identical on the wire but rejects `int` inputs to enforce
  /// type discipline.
  static const SqlDataType bit = SqlDataType._('bit');

  /// SQL `TEXT` / `NTEXT` / `CLOB` — long-form character data with
  /// no caller-supplied length cap. Accepts `String` only.
  /// Serialised as a UTF-8 string on the wire, identical to
  /// [SqlDataType.varChar] / [SqlDataType.nVarChar]; the distinction
  /// is purely semantic so call sites paired with a `TEXT` column
  /// read naturally.
  static const SqlDataType text = SqlDataType._('text');

  // -----------------------------------------------------------------
  // Engine-specific kinds. Each is wire-compatible with an existing
  // `ParamValue*` primitive (typically String or Binary) — the value
  // of routing through `SqlDataType` is the explicit semantic name in
  // the call site plus the per-kind input validation.
  //
  // **Important caveat shared by SQL Server `hierarchyid` and
  // `geography`, and by Oracle `BFILE`**: these types are usually NOT
  // bindable as a plain `?` placeholder of their native SQL type.
  // The driver expects a textual representation that must be wrapped
  // in a CAST or constructor function inside the SQL itself, e.g.:
  //
  //   INSERT INTO t(node) VALUES (CAST(? AS hierarchyid))
  //   INSERT INTO t(area) VALUES (geography::STGeomFromText(?, 4326))
  //   INSERT INTO t(doc)  VALUES (BFILENAME(?, ?))
  //
  // We document the convention here once and let each kind's doc
  // comment refer to it. The wire-level work this layer does is
  // exactly the same as `varChar` / `varBinary`; the value lives in
  // the **type-discipline at the call site**.
  // -----------------------------------------------------------------

  /// PostgreSQL **range** literal (`int4range`, `int8range`, `numrange`,
  /// `tsrange`, `tstzrange`, `daterange`, `int4multirange`, ...).
  /// Accepts a `String` literal in PostgreSQL's standard form, e.g.
  /// `'[1,10)'`, `'(1,5]'`, `'[2020-01-01,2020-12-31)'`. Wraps in
  /// [ParamValueString]; the server resolves the concrete range type
  /// from the column definition.
  ///
  /// We do **not** validate the bracket / value grammar — PostgreSQL
  /// accepts a wide variety of formats per concrete subtype and the
  /// server is the authoritative validator at execute-time.
  static const SqlDataType range = SqlDataType._('range');

  /// PostgreSQL **CIDR** / **INET** address literal (`192.168.1.0/24`,
  /// `2001:db8::/32`). Accepts a `String`. Validates against a
  /// pragmatic IPv4/IPv6 regex — accepts most well-formed inputs
  /// without pulling in a full RFC-grade parser. The server remains
  /// the authoritative validator at execute-time.
  ///
  /// Wraps in [ParamValueString]. PostgreSQL accepts the same string
  /// form for both `cidr` and `inet` columns.
  static const SqlDataType cidr = SqlDataType._('cidr');

  /// PostgreSQL **tsvector** (full-text search lexeme list). Accepts a
  /// `String` in `tsvector`'s native form: `'fat:1A cat:2B sat:3'` or
  /// the simpler space-separated lexeme list. Wraps in
  /// [ParamValueString]. Sintax is too permissive to validate
  /// usefully here; PostgreSQL's `to_tsvector` / cast is the real
  /// validator.
  static const SqlDataType tsvector = SqlDataType._('tsvector');

  /// SQL Server **hierarchyid** path (`'/'`, `'/1/'`, `'/1/2/3.5/'`).
  /// Accepts a `String`; validates that it starts with `/`, contains
  /// only `/`-separated decimal segments (each optionally with a
  /// `.fraction` for between-siblings inserts), and ends with `/`.
  ///
  /// **Caller is responsible for the CAST**: SQL Server's `hierarchyid`
  /// is not directly bindable from a parameter; the typical idiom is
  ///
  /// ```sql
  /// INSERT INTO t(node) VALUES (CAST(? AS hierarchyid))
  /// ```
  ///
  /// Wraps in [ParamValueString].
  static const SqlDataType hierarchyId = SqlDataType._('hierarchyid');

  /// SQL Server **geography** / **geometry** WKT literal
  /// (`'POINT(-122.349 47.651)'`, `'POLYGON((...))'`). Accepts a
  /// `String` in the OGC Well-Known Text form. Wraps in
  /// [ParamValueString].
  ///
  /// **Caller is responsible for the constructor function**: SQL
  /// Server's spatial types require an explicit constructor in the
  /// SQL, typically:
  ///
  /// ```sql
  /// INSERT INTO t(area) VALUES (geography::STGeomFromText(?, 4326))
  /// ```
  ///
  /// (The `4326` is the SRID — WGS-84 by convention; choose the SRID
  /// appropriate to your data.) For binary WKB payloads use
  /// [SqlDataType.varBinary] together with `geography::STGeomFromWKB`.
  static const SqlDataType geography = SqlDataType._('geography');

  /// SQL Server **geometry** WKT (planar) — same wire rules as
  /// [geography] (WKT string → [ParamValueString]). **Caller** supplies
  /// the constructor in SQL, e.g. `geometry::STGeomFromText(?, 0)` (SRID
  /// usually 0 for planar engine-local units).
  static const SqlDataType geometry = SqlDataType._('geometry');

  /// Oracle **RAW** binary data. Accepts `List<int>` (or `Uint8List`).
  /// Wraps in [ParamValueBinary] — wire-compatible with
  /// [SqlDataType.varBinary]; the distinction is purely semantic so
  /// call sites paired with an Oracle `RAW(N)` column read naturally.
  ///
  /// Oracle's legacy `RAW` is capped at 2000 bytes; modern
  /// `RAW(32767)` requires `MAX_STRING_SIZE = EXTENDED`. This layer
  /// does not enforce either limit — the server rejects oversize
  /// values at execute-time with a descriptive error.
  static const SqlDataType raw = SqlDataType._('raw');

  /// Oracle **BFILE** locator. Accepts a `String` containing a
  /// fully-formed `BFILENAME(...)` invocation, e.g.
  /// `"BFILENAME('DIR_OBJECT', 'docs/file.pdf')"`. Wraps in
  /// [ParamValueString].
  ///
  /// **`BFILE` is a pointer to an external file**, not the file
  /// content. In practice it is set via SQL like:
  ///
  /// ```sql
  /// INSERT INTO t(doc) VALUES (BFILENAME(?, ?))
  /// -- params: ['DIR_OBJECT', 'docs/file.pdf']
  /// ```
  ///
  /// In that case use two separate `varChar` parameters. This kind
  /// is provided for the less common case of binding a complete
  /// `BFILENAME(...)` text snippet that the server then evaluates.
  static const SqlDataType bfile = SqlDataType._('bfile');

  /// SQL `INTERVAL` (PostgreSQL `INTERVAL`, Oracle `INTERVAL DAY/YEAR`,
  /// Db2 `<n> SECONDS`). Accepts a [Duration] (formatted as
  /// `'<n> seconds'`, the broadest portable spelling — PostgreSQL,
  /// MySQL `INTERVAL`, Oracle `NUMTODSINTERVAL` accept it directly)
  /// or a `String` (passed through verbatim, for engines whose
  /// preferred syntax doesn't match the seconds form).
  ///
  /// Sub-second precision is preserved by emitting the fractional
  /// part as a decimal — e.g. `Duration(milliseconds: 1500)` becomes
  /// `'1.500 seconds'`. SQL Server has no `INTERVAL` type; its
  /// callers should compute differences with `DATEADD` / `DATEDIFF`
  /// instead.
  static const SqlDataType interval = SqlDataType._('interval');

  /// `INTERVAL ... YEAR TO MONTH` (ISO SQL / PostgreSQL / Oracle
  /// `INTERVAL 'y-m' YEAR TO MONTH`). Accepts:
  /// - a `String` in the engine’s native spelling (passed through
  ///   verbatim);
  /// - a `List<int>` of length 2, `[years, months]`, e.g. `[1, 2]`
  ///   for *one year and two months* (formatted as
  ///   `INTERVAL '1-2' YEAR TO MONTH`);
  /// - a `Map` with `int` values for keys `years` and `months` (same
  ///   meaning as the two-element list).
  ///
  /// The month field is normalised to `0..11` in the two-number form.
  /// Use a raw `String` if your engine needs a non-standard range.
  static const SqlDataType intervalYearToMonth =
      SqlDataType._('interval_year_to_month');
}
