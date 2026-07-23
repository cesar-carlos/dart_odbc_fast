/// Opt-in exports for native FFI, repository implementation, and other
/// infrastructure surfaces.
///
/// Most consumers should depend on `package:odbc_fast/odbc_fast.dart` only.
/// Import this library when you need direct access to `NativeOdbcConnection`,
/// `AsyncNativeOdbcConnection`, `OdbcRepositoryImpl`, OpenTelemetry FFI
/// bindings, or `OdbcPoolFactory`.
library;

export 'infrastructure/native/async_native_odbc_connection.dart';
export 'infrastructure/native/bindings/library_loader.dart'
    show preferLocalOdbcEngineBuild, resolvePreferredOdbcEngineFilePath;
export 'infrastructure/native/bindings/odbc_native.dart';
export 'infrastructure/native/bindings/opentelemetry_ffi.dart';
export 'infrastructure/native/driver_capabilities_mapper.dart';
export 'infrastructure/native/driver_capabilities_v3.dart';
export 'infrastructure/native/errors/async_error.dart';
export 'infrastructure/native/native_odbc_connection.dart';
export 'infrastructure/native/pool_options.dart';
export 'infrastructure/repositories/odbc_repository_impl.dart';
