# TROUBLESHOOTING.md - Solução de Problemas

This document covers common problems and their solutions for developing, building and deploying ODBC Fast.

## Índice

- [Desenvolvimento Local](#desenvolvimento-local)
- [Build e Compilação](#build-e-compilação)
- [FFI e Bindings](#ffi-e-bindings)
- [Runtime e execution](#runtime-e-execution)
  - [Async API hangs or times out](#async-api-hangs-or-times-out)
  - [Worker isolate crash](#worker-isolate-crash)
- [CI/CD e Releases](#cicd-e-releases)
- [ODBC e connections](#odbc-e-connections)

## Desenvolvimento Local

### Dart pub get failure

**Sintoma**:

```
Error: Could not resolve all dependencies.
```

**Solução**:

```bash
# Limpar cache
dart pub cache repair

# Reinstalar
dart pub get
```

### Tests failed with "odbc_engine.dll not found" / "Failed to lookup symbol 'odbc_init'"

**Sintoma**:

```
StateError: ODBC engine library not found
```

ou

```
Invalid argument(s): Failed to lookup symbol 'odbc_init': error code 127
```

**Cause**: Rust binary has not been compiled or is not in a location that the loader looks for.

**Solução**:

1. **Compilar e deixar no local correto** (recomendado):

   ```bash
   cd native
   cargo build --release
   ```

   The binary will be generated in `native/target/release/` (workspace), which is the first location the loader uses. It is not necessary to copy anything.

2. **Verify that the binary exists** (from the project root):

   ```bash
   # Windows
   dir native\target\release\odbc_engine.dll

   # Linux
   ls native/target/release/libodbc_engine.so
   ```

3. **If the DLL was generated in another directory** (e.g. to avoid "Access Denied" when overwriting): copy it to the correct location. See [BUILD.md - Copy the DLL to the correct location](BUILD.md#copy-the-dll-to-the-correct-location).

### Ffigen not gera bindings

**Sintoma**:

```
ffigen failed to generate bindings
```

**Causas possíveis**:

1. **Header file not existe**:

```bash
# Verificar
ls native/odbc_engine/include/odbc_engine.h

# Se not existir, buildar o Rust primeiro
cd native/odbc_engine
cargo build
```

2. **Clang/LLVM not instalado (Linux)**:

```bash
sudo apt-get install -y libclang-dev llvm
```

3. **configuration incorreta do ffigen.yaml**:

```yaml
output: "lib/infrastructure/native/bindings/odbc_bindings.dart"
headers:
  - "native/odbc_engine/include/odbc_engine.h"
```

## Build e Compilação

### Cargo build muito lento

**Sintoma**: Build demora mais de 10 minutos

**Causa**: Sanitizers ativos

**Verificar**:

```bash
# native/odbc_engine/.cargo/config.toml
# remove se existir:
[target.x86_64-unknown-linux-gnu]
rustflags = [
    "-C", "link-arg=-fsanitize=address",
    "-C", "link-arg=-fsanitize=undefined",
]
```

**Resultado esperado**: Build time de 3-5 minutos

### Cross-compilation failure

**Sintoma**:

```
error: linker `x86_64-w64-mingw32-gcc` not found
```

**Solução (Linux → Windows)**:

```bash
sudo apt-get install -y mingw-w64
rustup target add x86_64-pc-windows-msvc
```

### ODBC headers not encontrados

**Sintoma** (Linux):

```
fatal error: sql.h: No such file or directory
```

**Solução**:

```bash
sudo apt-get install -y unixodbc unixodbc-dev
```

### cbindgen failure

**Sintoma**:

```
error: failed to run custom build command for `odbc_engine`
```

**Causa**: build.rs executando cbindgen falhou

**Solução**:

```bash
# Instalar cbindgen
cargo install cbindgen

# Verificar configuration
cat native/odbc_engine/cbindgen.toml
```

## FFI e Bindings

### "Invalid function pointer" when calling native functions

**Sintoma**:

```
Invalid argument(s): Invalid function pointer
```

**Cause**: Bindings out of sync with the header

**Solução**:

```bash
# Regenerar bindings
dart run ffigen -v info

# Verificar que a version do binário corresponde
cd native && cargo build --release
```

### Segmentation fault when calling native function

**Sintoma**: Processo Dart crasha

**Causas possíveis**:

1. **Mismatch entre Dart e Rust ABI**:

```bash
# Verificar que está usando a version correta do binário
rm ~/.cache/odbc_fast/* -rf
dart pub get
```

2. **Memory corruption no Rust**:

```bash
# Rodar com sanitizers (mustlopment)
cd native/odbc_engine
RUSTFLAGS="-Z sanitizer=address" cargo test
```

3. **Types incorretos nos bindings**:

```dart
// Verificar que o tipo no binding corresponde ao Rust
// Ex: IntPtr vs int vs Pointer<Void>
```

## Runtime e execution

### Biblioteca not encontrada / onde colocar a DLL

If the app or tests fail to load the library (e.g. "ODBC engine library not found" or "Failed to lookup symbol 'odbc_init'"), the DLL/.so needs to be in one of the locations that the loader uses. The search order and how to copy the DLL to the correct location are in **[BUILD.md - Where the DLL must be and Copy the DLL](BUILD.md#where-the-dll-must-be-search-order)**. Summary:

- **Development**: `cd native && cargo build --release` generates in `native/target/release/` (it is already the correct location).
- **Manual download**: download from [GitHub Release](https://github.com/cesar-carlos/dart_odbc_fast/releases) and place it in `native/target/release/odbc_engine.dll` (Windows) or `native/target/release/libodbc_engine.so` (Linux).

### Async API hangs or times out

If the UI freezes when using `AsyncNativeOdbcConnection` or requests never complete, use `requestTimeout` to avoid indefinite hangs:

```dart
final async = AsyncNativeOdbcConnection(
  requestTimeout: Duration(seconds: 30), // Default; null = no limit
);
```

If the worker does not respond within the timeout, requests throw `AsyncError` with code `requestTimeout`. Call `dispose()` when done; pending requests complete with `workerTerminated` instead of hanging.

### Worker isolate crash

If the async worker isolate terminates unexpectedly (crash, OOM, or external kill), the client receives errors for all pending requests (e.g. `workerTerminated`). You can optionally enable automatic recovery:

- **`AsyncNativeOdbcConnection(autoRecoverOnWorkerCrash: true)`**: after `_failAllPending`, the connection calls `recoverWorker()` (dispose + re-initialize). Use this only if you want the same instance to be reusable; note that **previous connection IDs are invalid** — callers must reconnect after a worker crash.
- **`WorkerCrashRecovery.handleWorkerCrash(async, error, stackTrace)`** (in `lib/infrastructure/native/isolate/error_recovery.dart`): can be invoked from your own `ReceivePort` listener to trigger the same recovery (log + `async.recoverWorker()`).

After recovery, always **reconnect** (obtain new connection IDs); do not reuse IDs from before the crash. See [OBSERVABILITY.md](OBSERVABILITY.md) for logging.

### "ODBC connection failed"

**Sintoma**:

```
OdbcError.connectionFailed: IM002 [Data source name not found]
```

**Solução**:

1. **Verificar DSN**:

```bash
# Windows
odbcconf.exe

# Linux
odbcinst -q -d
cat /etc/odbcinst.ini
cat /etc/odbc.ini
```

2. **Configurar DSN corretamente**:

```dart
final service = OdbcService();
final result = await service.connect(
  'Driver={ODBC Driver 17 for SQL Server};'
  'Server=localhost;'
  'Database=testdb;'
  'UID=sa;'
  'PWD=password;'
);
```

### Memory leak em queries longas

**Sintoma**: Memória cresce indefinidamente

**Causa**: Result sets not sendo liberados

**Solução**:

```dart
// Usar streaming para grandes resultados
final result = await service.executeQueryStream(
  query,
  batchSize: 1000,
);

await for (final batch in result) {
  // Processar batch
  // Memória é liberada automaticamente
}
```

### "Buffer too small" (result set > 16 MB)

**Sintoma**:

```
OdbcError: Buffer too small: need XXXXX bytes, got 16777216
```

**Cause**: The serialized query result exceeds the default buffer limit (16 MB).

**Soluções**:

1. **Increase the connection buffer** (for known large result sets):

```dart
await service.connect(
  connectionString,
  options: ConnectionOptions(
    maxResultBufferBytes: 32 * 1024 * 1024, // 32 MB
  ),
);
```

2. **Page the query in SQL** (recommended for very large tables):

```sql
-- SQL Server: OFFSET/FETCH
SELECT * FROM Produto ORDER BY Id OFFSET 0 ROWS FETCH NEXT 1000 ROWS ONLY;

-- Ou TOP + chave
SELECT TOP 1000 * FROM Produto ORDER BY Id;
```

### Pool de connections esgotado

**Sintoma**:

```
OdbcError.poolExhausted: Maximum pool size reached
```

**Solução**:

```dart
// Aumentar tamanho do pool
await service.poolCreate(
  connectionString,
  maxConnections: 20,  // ← Aumentar
);

// Ou garantir que connections são liberadas
try {
  final conn = await service.poolGetConnection();
  // Usar connection
} finally {
  await service.poolReleaseConnection(conn);
}
```

## CI/CD e Releases

### GitHub Actions workflow failure with "cp: cannot stat"

**Sintoma** (workflow):

```
cp: cannot stat 'native/odbc_engine/target/.../libodbc_engine.so'
```

**Causa**: Workspace Cargo cria binário em `native/target/`, not `native/odbc_engine/target/`

**Solução**:

```yaml
# .github/workflows/release.yml
- name: Rename artifact
  run: |
    mkdir -p uploads
    cp native/target/${{ matrix.target }}/release/${{ matrix.artifact }} \
       uploads/${{ matrix.artifact }}
```

### Release workflow returns 403 Forbidden

**Sintoma**:

```
GitHub release failed with status: 403
```

**Cause**: Workflow without permission to create releases

**Solução**:

```yaml
# .github/workflows/release.yml
permissions:
  contents: write # ← add
```

### "Pattern 'uploads/\*' does not match any files"

**Sintoma** (release workflow):

```
Pattern 'uploads/*' does not match any files
```

**Cause**: Artifacts are downloaded with subdirectory

**Solução**:

```yaml
- name: Download all artifacts
  uses: actions/download-artifact@v4
  with:
    path: uploads/
    pattern: "*"
    merge-multiple: true # ← Importante
```

### Download automático not funciona

**Symptom**: `dart pub get` does not download the binary

**Verificar**:

1. **URL está correta** (hook/build.dart):

```dart
final url = 'https://github.com/cesar-carlos/dart_odbc_fast'
    '/releases/download/v$version/$libName';
```

2. **Arquivos existem na release**:

```bash
# Verificar no GitHub que os arquivos estão na RAIZ
# not em: uploads/odbc_engine.dll
# must ser: odbc_engine.dll
```

3. **version corresponde**:

```bash
# pubspec.yaml version must corresponder à tag no GitHub
version: 0.1.5  # → v0.1.5
```

### ffigen no CI failure with "--verbose"

**Sintoma**:

```
FormatException: Missing argument for "--verbose"
```

**Sausa**: Sintaxe incorreta do ffigen

**Solução**:

```yaml
# Errado
dart run ffigen --verbose

# Correto
dart run ffigen -v info
```

## ODBC e connections

### "Driver not found" no Windows

**Sintoma**:

```
IM002 [Microsoft][ODBC Driver Manager] Data source name not found
```

**Solução**:

1. **Install the correct ODBC driver**:
   - SQL Server: [ODBC Driver 17 for SQL Server](https://docs.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server)
   - PostgreSQL: [psqlODBC](https://odbc.postgresql.org/)

2. **Verificar drivers instalados**:

```powershell
Get-OdbcDriver -Name "ODBC Driver*"
```

3. **Usar nome correto do driver**:

```dart
// Errado
'Driver={SQL Server};...'

// Correto
'Driver={ODBC Driver 17 for SQL Server};...'
```

### "unixODBC Driver Manager not found" no Linux

**Sintoma**:

```
error while loading shared libraries: libodbc.so.2
```

**Solução**:

```bash
sudo apt-get install -y unixodbc unixodbc-dev

# Verificar
odbcinst -j
```

### connection cai após alguns minutos

**Sintoma**: `OdbcError.connectionLost` após tempo

**Causa**: Timeout de connection ou firewall

**Solução**:

```dart
// Usar pooling com health check
await service.poolCreate(
  connectionString,
  maxConnections: 10,
);

// Pool valida connections automaticamente
final conn = await service.poolGetConnection();
// connection é validada antes de ser returnsda
```

## Diagnóstico

### Habilitar logs detalhados

**Dart**:

```dart
import 'package:logging/logging.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.message}');
  });

  // Seu código
}
```

**Rust**:

```bash
RUST_LOG=debug cargo run
```

### Verificar versões

```bash
# Dart
dart --version

# Rust
rustc --version
cargo --version

# ODBC
# Windows
Get-OdbcDriver

# Linux
odbcinst -q -d
odbcinst --version
```

### Testar binário manualmente

```bash
# Windows
dumpbin /DEPENDENTS native/target/release/odbc_engine.dll

# Linux
ldd native/target/release/libodbc_engine.so

# Verificar símbolos
nm native/target/release/libodbc_engine.so | grep Odbc
```

## Pedindo Ajuda

Se você not conseguiu resolver seu problema:

1. **Verifique a documentation**:
   - [BUILD.md](BUILD.md) - Build e desenvolvimento
   - [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) - Pipeline de releases
   - [README.md](../README.md) - Visão geral

2. **Search issues existentes**:
   https://github.com/cesar-carlos/dart_odbc_fast/issues

3. **create nova issue**:
   - Describe the problem in detail
   - Inclua mensagens de erro completas
   - Informe seu sistema operacional e versões
   - Provide steps to reproduce

4. **Useful logs to include**:
   - `dart --version`
   - `rustc --version`
   - Full error output
   - Arquivo de configuration (sem credenciais)



