/// Native result wire encoding requested for query execution.
///
/// [rowMajor] is the stable default and matches the historical v1 row buffer.
/// [columnar] and [columnarCompressed] are opt-in diagnostics/performance
/// paths; callers should compare results and benchmark before making them the
/// default for a workload.
enum ResultEncoding {
  rowMajor(0),
  columnar(1),
  columnarCompressed(2);

  const ResultEncoding(this.wireCode);

  /// ABI code passed to native `_options` FFI entry points.
  final int wireCode;

  /// True for [columnar] and [columnarCompressed] wire layouts (v2).
  bool get isColumnar => this != ResultEncoding.rowMajor;
}
