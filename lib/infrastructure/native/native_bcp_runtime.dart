import 'dart:io' show Platform;

import 'package:odbc_fast/domain/entities/driver_capabilities.dart';

/// Mirrors the native `ODBC_ENABLE_UNSTABLE_NATIVE_BCP` guardrail.
///
/// Native SQL Server BCP (`sqlserver-bcp` feature) is compiled out of default
/// builds and disabled at runtime unless this variable is set to a truthy value
/// (`1`, `true`, `yes`, case-insensitive). Use [isNativeBcpAvailable] with
/// [DriverCapabilities.supportsNativeBcp] from `odbc_get_driver_capabilities`
/// JSON for end-to-end eligibility checks.
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

/// True when native SQL Server BCP may run: engine capability from native JSON
/// plus the runtime env guard on Windows hosts.
bool isNativeBcpAvailable(DriverCapabilities capabilities) {
  if (!capabilities.supportsNativeBcp) {
    return false;
  }
  if (!Platform.isWindows) {
    return false;
  }
  return isUnstableNativeBcpEnabled;
}
