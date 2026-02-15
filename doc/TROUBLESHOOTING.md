# TROUBLESHOOTING.md - Problemas comuns

## 1. Biblioteca nativa nao encontrada

Sintomas:

- `StateError: ODBC engine library not found`
- `Failed to lookup symbol 'odbc_init'`

Resolucao:

```bash
cd native
cargo build --release
```

Verifique se o arquivo existe:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

Se a build foi feita em `native/odbc_engine/target/release`, copie para `native/target/release`.

## 2. `dart pub get` nao baixou binario

O hook pode pular download em CI/pub.dev.

Verifique:

1. A tag/release correspondente existe no GitHub (`vX.Y.Z`).
2. Os assets estao na raiz da release (`odbc_engine.dll`, `libodbc_engine.so`).
3. `pubspec.yaml` esta com a mesma versao da tag.

## 3. Build Rust falhando por dependencias

Linux:

```bash
sudo apt-get install -y unixodbc unixodbc-dev libclang-dev llvm
```

Windows:

- garanta toolchain MSVC ativa (`rustup default stable-msvc`).

## 4. `ffigen` falha ao gerar bindings

Checklist:

1. Header existe: `native/odbc_engine/include/odbc_engine.h`
2. `cbindgen` instalado: `cargo install cbindgen`
3. Comando correto: `dart run ffigen -v info`

## 5. Async API travando ou timeout

Use timeout explicito e descarte conexao async corretamente:

```dart
final conn = AsyncNativeOdbcConnection(
  requestTimeout: Duration(seconds: 30),
);

// ...
await conn.dispose();
```

Codigos esperados em erro: `requestTimeout` e `workerTerminated`.

## 6. Erro ODBC IM002 (driver/DSN)

Mensagem tipica:

- `Data source name not found`

Verifique:

- Nome do driver na connection string
- DSN configurado no sistema
- Driver instalado (Windows: `Get-OdbcDriver`, Linux: `odbcinst -q -d`)

## 7. `Buffer too small` em result sets grandes

Aumente buffer por conexao:

```dart
ConnectionOptions(maxResultBufferBytes: 32 * 1024 * 1024)
```

Ou pagina a query no SQL (TOP/OFFSET-FETCH).

## 8. Workflow de release falha

Erros comuns:

- `cp: cannot stat ...`
- `Pattern 'uploads/*' does not match any files`
- `403` ao criar release

Consulte o guia: [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)

## 9. Diagnostico rapido

```bash
dart --version
rustc --version
cargo --version
```

Linux:

```bash
odbcinst -q -d
odbcinst --version
```

Windows:

```powershell
Get-OdbcDriver
```

## 10. Quando abrir issue

Abra issue em https://github.com/cesar-carlos/dart_odbc_fast/issues com:

1. erro completo
2. SO e versoes (Dart/Rust/driver ODBC)
3. passos para reproduzir
4. trecho minimo de codigo

## 11. Benchmark Rust (bulk array vs parallel) foi pulado

Se `cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture` nao executar benchmark:

1. defina `ENABLE_E2E_TESTS=true`
2. configure `ODBC_TEST_DSN` valido
3. confirme conectividade ODBC local (driver + DSN)

Opcional:

- ajuste volume com `BULK_BENCH_SMALL_ROWS` e `BULK_BENCH_MEDIUM_ROWS`
