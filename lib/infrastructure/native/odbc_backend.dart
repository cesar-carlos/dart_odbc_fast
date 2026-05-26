import 'package:odbc_fast/infrastructure/native/async_native_odbc_connection.dart';
import 'package:odbc_fast/infrastructure/native/native_odbc_connection.dart';

/// Typed wrapper around a native ODBC connection used by the repository
/// layer. Replaces the historical `dynamic _native` field with a sealed
/// hierarchy so consumers can dispatch via exhaustive pattern matching
/// instead of repeated `as` casts.
///
/// Two variants are supported:
///
/// - [SyncBackend] wraps a [NativeOdbcConnection] (blocking FFI). All
///   operations return values directly.
/// - [AsyncBackend] wraps an [AsyncNativeOdbcConnection] (worker isolate).
///   All operations return [Future]s.
///
/// The repository does not assume value identity — it always reaches the
/// underlying connection through `connection`. Construct one via the
/// helper factory [OdbcBackend.fromNative] or directly with the variant
/// constructors when the type is known statically.
sealed class OdbcBackend {
  const OdbcBackend();

  /// Builds a backend from an untyped reference. Accepts only
  /// [NativeOdbcConnection] or [AsyncNativeOdbcConnection]; throws
  /// [ArgumentError] otherwise. Use this on FFI / DI seams where the
  /// concrete type is only known at runtime; prefer the typed
  /// constructors elsewhere.
  static OdbcBackend fromNative(Object native) => switch (native) {
        final NativeOdbcConnection sync => SyncBackend(sync),
        final AsyncNativeOdbcConnection async => AsyncBackend(async),
        _ => throw ArgumentError.value(
            native,
            'native',
            'must be NativeOdbcConnection or AsyncNativeOdbcConnection',
          ),
      };

  /// Whether this backend dispatches calls to a worker isolate.
  bool get isAsync;
}

/// Synchronous backend backed by a [NativeOdbcConnection].
final class SyncBackend extends OdbcBackend {
  const SyncBackend(this.connection);

  /// The wrapped sync ODBC connection.
  final NativeOdbcConnection connection;

  @override
  bool get isAsync => false;
}

/// Asynchronous backend backed by an [AsyncNativeOdbcConnection].
final class AsyncBackend extends OdbcBackend {
  const AsyncBackend(this.connection);

  /// The wrapped async ODBC connection.
  final AsyncNativeOdbcConnection connection;

  @override
  bool get isAsync => true;
}
