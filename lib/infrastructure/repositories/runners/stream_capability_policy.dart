import 'package:odbc_fast/infrastructure/repositories/runners/odbc_ffi_dispatch.dart';

/// Decides whether native streaming FFIs are available and which path to use.
class StreamCapabilityPolicy {
  const StreamCapabilityPolicy(this.ffi);

  final OdbcFfiDispatch ffi;

  /// Whether multi-result batched streaming can use native FFIs.
  bool get supportsStreamQueryMulti =>
      ffi.isAsync || ffi.sync.supportsStreamQueryMulti;
}
