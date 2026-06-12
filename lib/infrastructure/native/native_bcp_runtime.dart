import 'dart:io' show Platform;

/// Mirrors the native `ODBC_ENABLE_UNSTABLE_NATIVE_BCP` guardrail.
///
/// Native SQL Server BCP (`sqlserver-bcp` feature) is compiled out of default
/// builds and disabled at runtime unless this variable is set to a truthy value
/// (`1`, `true`, `yes`, case-insensitive). The capability is **not** exposed
/// in `odbc_get_driver_capabilities` JSON — check this helper or log the env
/// when diagnosing bulk-insert performance on Windows.
bool get isUnstableNativeBcpEnabled {
  final raw = Platform.environment['ODBC_ENABLE_UNSTABLE_NATIVE_BCP'];
  if (raw == null || raw.trim().isEmpty) {
    return false;
  }
  switch (raw.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
      return true;
    default:
      return false;
  }
}
