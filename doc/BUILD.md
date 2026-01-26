# Build Guide - ODBC Fast

Guia para construir o projeto ODBC Fast: biblioteca Rust e integração Dart FFI.

## Pré-requisitos

### Windows
- **Rust**: [rustup.rs](https://rustup.rs/)
- **Dart SDK**: >= 3.0.0
- **ODBC Driver Manager**: Incluído no Windows; drivers específicos (SQL Server, etc.) conforme necessidade

### Linux
- **Rust**: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Dart**: [dart.dev/get-dart](https://dart.dev/get-dart)
- **unixODBC**: `sudo apt-get install unixodbc unixodbc-dev` (Ubuntu/Debian)

### macOS
- **Rust**: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **Dart**: `brew install dart`
- **unixODBC**: `brew install unixodbc`

## Build automatizado

### Windows (PowerShell)
```powershell
.\scripts\build.ps1
```

### Linux/macOS (Bash)
```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

## Build manual

### 1. Biblioteca Rust

```bash
cd native/odbc_engine
cargo build --release
```

- Gera a DLL/shared library em `target/release/`
- Gera o header C `include/odbc_engine.h` via `build.rs` + cbindgen

### 2. Bindings Dart

Os bindings em `lib/infrastructure/native/bindings/` são **mantidos manualmente** e espelham o header C. Não é necessário rodar ffigen para o fluxo padrão.

Opcionalmente, para regenerar a partir do header (requer LLVM/Clang):

```bash
dart run ffigen --config ffigen.yaml
```

### 3. Verificação

```powershell
# Windows
Test-Path native\odbc_engine\target\release\odbc_engine.dll

# Linux / macOS
test -f native/odbc_engine/target/release/libodbc_engine.so
test -f native/odbc_engine/target/release/libodbc_engine.dylib
```

## Estrutura de build

```
dart_odbc_fast/
├── native/odbc_engine/
│   ├── Cargo.toml, cbindgen.toml, build.rs
│   ├── src/ffi/          # FFI exportado
│   ├── include/
│   │   └── odbc_engine.h # Gerado pelo build
│   └── target/release/
│       └── odbc_engine.* # Biblioteca
├── lib/infrastructure/native/
│   ├── bindings/         # odbc_bindings, odbc_native, library_loader, ffi_buffer_helper
│   ├── protocol/         # binary_protocol, param_value, bulk_insert_builder
│   └── ...
└── scripts/              # build.ps1, build.sh, validate_all.ps1, etc.
```

## Funções FFI (31)

O header `native/odbc_engine/include/odbc_engine.h` é a referência. Resumo:

| Área | Funções |
|------|---------|
| **Init** | `odbc_init` |
| **Conexão** | `odbc_connect`, `odbc_disconnect` |
| **Transações** | `odbc_transaction_begin`, `odbc_transaction_commit`, `odbc_transaction_rollback` |
| **Erros / Métricas** | `odbc_get_error`, `odbc_get_structured_error`, `odbc_get_metrics` |
| **Queries** | `odbc_exec_query`, `odbc_exec_query_params`, `odbc_exec_query_multi` |
| **Prepared** | `odbc_prepare`, `odbc_execute`, `odbc_cancel`, `odbc_close_statement` |
| **Streaming** | `odbc_stream_start`, `odbc_stream_start_batched`, `odbc_stream_fetch`, `odbc_stream_close` |
| **Catálogo** | `odbc_catalog_tables`, `odbc_catalog_columns`, `odbc_catalog_type_info` |
| **Pool** | `odbc_pool_create`, `odbc_pool_get_connection`, `odbc_pool_release_connection`, `odbc_pool_health_check`, `odbc_pool_get_state`, `odbc_pool_close` |
| **Bulk** | `odbc_bulk_insert_array`, `odbc_bulk_insert_parallel` (stub) |

## Troubleshooting

| Erro | Ação |
|------|------|
| Cargo não encontrado | Instalar Rust via rustup; garantir `~/.cargo/bin` no PATH |
| Dart não encontrado | Instalar Dart SDK ou usar o do Flutter |
| Header não encontrado | Rodar `cargo build --release` em `native/odbc_engine` |
| ffigen falha | Confirmar header gerado e `ffigen.yaml`; opcional para uso normal |
| ODBC driver não encontrado | Instalar driver (ex.: SQL Server) e configurar DSN |

## Validação

```powershell
.\scripts\validate_all.ps1
```

Ou manualmente: `dart analyze`, `dart test`, `cargo test` em `native/odbc_engine`.

## Referências

- [Rust FFI](https://doc.rust-lang.org/nomicon/ffi.html)
- [Dart FFI](https://dart.dev/guides/libraries/c-interop)
- [cbindgen](https://github.com/eqrion/cbindgen)
- [ffigen](https://pub.dev/packages/ffigen)
