# Migration Guide: Sync to Async API

This guide helps migrate existing code from sync to async API (v0.2.0+).

## API Changes

### Before (Sync - v0.1.x)

```dart
final locator = ServiceLocator();
locator.initialize();

final service = locator.service;
await service.initialize();

final result = await service.executeQuery(connId, sql);
// Blocked main thread during execution
```

### After (Async - v0.2.0)

```dart
final locator = ServiceLocator();
locator.initialize(useAsync: true);

final service = locator.asyncService;
await service.initialize();

final result = await service.executeQuery(connId, sql);
// Runs in worker isolate, main thread stays responsive
```

## Breaking Changes

### 1. ServiceLocator.initialize()

**New parameter**: `useAsync`

```dart
// Before
locator.initialize();

// After (for async)
locator.initialize(useAsync: true);
```

### 2. AsyncNativeOdbcConnection constructor

**No longer accepts** a sync connection. The worker isolate owns its own native connection.

```dart
// Before
final native = NativeOdbcConnection();
final async = AsyncNativeOdbcConnection(native);

// After
final async = AsyncNativeOdbcConnection();
await async.initialize();
```

### 3. Shutdown cleanup

**New**: `ServiceLocator.shutdown()`

Call on app exit when using async to release the worker isolate:

```dart
@override
void dispose() {
  ServiceLocator().shutdown();
  super.dispose();
}
```

## Compatibility

Existing code that does **not** use `useAsync: true` continues to work unchanged:

```dart
final locator = ServiceLocator();
locator.initialize();
final service = locator.service;
```

## When to Migrate to Async

**Migrate if:**
- Flutter application (UI freezing is a problem)
- Long queries (>100ms)
- Multiple parallel queries

**Do not migrate if:**
- Simple CLI tool
- Very fast queries (<10ms)
- Blocking is acceptable

## Performance

- Worker spawn (one-time): 50–100ms
- Per-operation overhead: 1–3ms
- For a 100ms query, overhead is 1–3% (negligible)

## Troubleshooting

### "Worker not initialized"

```dart
// Wrong: forgot initialize
final service = locator.asyncService;
await service.connect(dsn);

// Correct
await service.initialize();
await service.connect(dsn);
```

### "StateError: useAsync not true"

```dart
// Wrong: did not initialize with async
locator.initialize();
final service = locator.asyncService;

// Correct
locator.initialize(useAsync: true);
final service = locator.asyncService;
```

## Examples

See [`example/async_demo.dart`](../example/async_demo.dart) for a full demonstration.
