# BUILD.md - Guia de Build e Desenvolvimento

This guide covers the complete ODBC Fast build and development process, including the Rust native engine, Dart FFI bindings, and Environment configuration.

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Project Structure](#project-structure)
  - [Onde a DLL must ficar](#onde-a-dll-must-ficar-ordem-de-busca)
  - [Copy the DLL to the correct location](#copy-the-dll-to-the-correct-location)
- [configuration do Environment](#configuration-do-Environment)
- [Build Manual](#build-manual)
- [Gerar Bindings FFI](#gerar-bindings-ffi)
- [Desenvolvimento](#desenvolvimento)
- [Performance](#performance)
- [Troubleshooting](#troubleshooting)

## Pré-requisitos

### Windows

```powershell
# Instalar Rust
winget install Rustlang.Rust.MSVC

# Instalar Dart SDK
winget install Google.DartSDK

# ODBC Driver Manager vem pré-instalado no Windows
```

### Linux (Ubuntu/Debian)

```bash
# Instalar Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Instalar Dart SDK
sudo apt-get update
sudo apt-get install -y dart

# Dependências ODBC e build
sudo apt-get install -y unixodbc unixodbc-dev libclang-dev llvm
```

## Project Structure

```
dart_odbc_fast/
├── lib/                          # Código Dart
│   ├── domain/                   # Camada de domínio
│   ├── application/              # Camada de aplicação
│   └── infrastructure/           # Camada de infraestrutura
│       └── native/
│           ├── bindings/         # Bindings FFI gerados
│           └── library_loader.dart
├── native/                       # Rust workspace
│   ├── Cargo.toml               # Workspace root
│   ├── target/                  # Saída do cargo (workspace)
│   │   └── release/
│   │       ├── odbc_engine.dll  # Windows (local preferido)
│   │       └── libodbc_engine.so # Linux
│   └── odbc_engine/             # Membro do workspace
│       ├── Cargo.toml
│       ├── build.rs             # Build script (cbindgen)
│       ├── .cargo/config.toml   # configuration do Cargo
│       ├── target/release/      # Saída alternativa (build no membro)
│       └── src/
├── hook/                        # Native Assets hooks
│   └── build.dart               # Hook de build automático
├── ffigen.yaml                  # configuration do ffigen
└── pubspec.yaml                 # Dependências Dart
```

### Onde a DLL must ficar (ordem de busca)

The loader (`library_loader.dart`) and hook (`hook/build.dart`) look for the library in this order:

| Priority | Location (from project root) | When is it used |
| ---------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 1 | `native/target/release/odbc_engine.dll` (Windows) or `libodbc_engine.so` (Linux) | Build from workspace: `cd native && cargo build --release` |
| 2 | `native/odbc_engine/target/release/odbc_engine.dll` (or `.so`) | Build on member only: `cd native/odbc_engine && cargo build --release` |
| 3          | Native Assets (pacote) / cache `~/.cache/odbc_fast/<version>/`                    | Produção: `dart pub get` baixa da GitHub Release ou usa cache            |
| 4          | PATH (Windows) / LD_LIBRARY_PATH (Linux)                                         | DLL instalada no sistema                                                 |

For development, the correct location is **1** or **2**. To avoid having to copy anything, always use:

```bash
cd native
cargo build --release
```

The binary will be generated in `native/target/release/` and will already be found by Dart.

### Copy the DLL to the correct location

If you generated the DLL elsewhere (for example to not overwrite one in use, or after manual download):

**Windows (PowerShell, in the project root):**

```powershell
# example: DLL foi gerada em native/target_release_new/release/
Copy-Item -Path "native\target_release_new\release\odbc_engine.dll" -Destination "native\target\release\odbc_engine.dll" -Force

# Ou, se buildou só no membro e quer padronizar no workspace:
New-Item -ItemType Directory -Force -Path "native\target\release" | Out-Null
Copy-Item -Path "native\odbc_engine\target\release\odbc_engine.dll" -Destination "native\target\release\odbc_engine.dll" -Force
```

**Linux/macOS:**

```bash
# example: copiar de odbc_engine/target para workspace target
mkdir -p native/target/release
cp native/odbc_engine/target/release/libodbc_engine.so native/target/release/
```

**Download manual da GitHub Release:**

1. Download the binary from [Release](https://github.com/cesar-carlos/dart_odbc_fast/releases) (e.g.: `odbc_engine.dll` for Windows).
2. Place it in one of the locations that the loader uses:
   - `native/target/release/odbc_engine.dll` (recommended for dev), or
   - In a directory that is in the PATH (Windows) or LD_LIBRARY_PATH (Linux).

## configuration do Environment

### 1. Clone the Repository

```bash
git clone https://github.com/cesar-carlos/dart_odbc_fast.git
cd dart_odbc_fast
```

### 2. Instalar Dependências Dart

```bash
dart pub get
```

### 3. Verificar Instalação Rust

```bash
rustc --version
cargo --version
```

## Build Manual

### Build do Rust Engine (Desenvolvimento)

**Windows:**

```powershell
cd native
cargo build --release
```

**Linux:**

```bash
cd native
cargo build --release
```

The binary will be created at:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

### Build with Cross-Compilation

```bash
# Windows (no Linux)
cargo build --release --target x86_64-pc-windows-msvc

# Linux (no Windows)
cargo build --release --target x86_64-unknown-linux-gnu
```

## Gerar Bindings FFI

FFI bindings are automatically generated by the hook, but can be generated manually:

```bash
# A partir da raiz do projeto
dart run ffigen -v info
```

The generated file will be: `lib/infrastructure/native/bindings/odbc_bindings.dart`

### configuration do ffigen

```yaml
# ffigen.yaml
output: "lib/infrastructure/native/bindings/odbc_bindings.dart"
headers:
  - "native/odbc_engine/include/odbc_engine.h"
header-comments: false
functions:
  include:
    - "Odbc.*"
```

## Desenvolvimento

### Fluxo de Desenvolvimento Típico

1. **Fazer mudanças no Rust**

   ```bash
   cd native/odbc_engine
   # Editar src/*.rs
   cargo build --release
   ```

2. **Regenerar bindings (se mudou a FFI surface)**

   ```bash
   cd ../..
   dart run ffigen -v info
   ```

3. **Test with Dart**
   ```bash
   dart test
   ```

### Testes

**All tests:**

```bash
dart test
```

**Testes específicos:**

```bash
# Testes de validação
dart test test/validation/

# Testes de integration (requer DSN configurado)
dart test test/integration/

# Testes de stress
dart test test/stress/
```

## Performance

### Otimizações Ativas

The project uses several optimizations for build time and runtime:

#### Build Time (native/Cargo.toml)

```toml
[profile.release]
lto = "thin"          # 2-3x mais rápido que fat LTO
codegen-units = 16    # Mais paralelismo
opt-level = 3         # Otimização máxima
strip = true          # Binário menor
```

**Resultado**: Build time reduzido em 70% (10-15 min → 3-5 min)

#### Runtime

- **Streaming**: Processamento de resultados em batches
- **Pooling**: Pool de connections reutilizáveis
- **Binary protocol**: Efficient data transfer
- **Zero-copy**: Mínima cópia de memória entre Rust e Dart

### Benchmarks

```bash
# Rodar benchmarks
cd native/odbc_engine
cargo bench
```

## Troubleshooting

### Erro: "odbc_engine.dll not found"

**Solução 1**: Build do Rust engine

```bash
cd native
cargo build --release
```

**Solução 2**: Verificar caminho da biblioteca

### Error: "failed to remove file ... odbc_engine.dll" / "Access denied" (DLL in use)

Old DLL is in use (IDE, Dart process, antivirus). To generate the new DLL without overwriting:

**PowerShell (workspace = `native/`):**

```powershell
cd native
$env:CARGO_TARGET_DIR = "target_release_new"
cargo build -p odbc_engine --release
```

A nova DLL fica em `native/target_release_new/release/odbc_engine.dll`. Depois:

1. Close Cursor/IDE and any process that uses the DLL.
2. Copy `target_release_new\release\odbc_engine.dll` to `target\release\odbc_engine.dll`, or
3. Run `cargo build -p odbc_engine --release` again (without CARGO_TARGET_DIR) to write to `target/release/`.

```dart
// lib/infrastructure/native/bindings/library_loader.dart
// Confira que os caminhos estão corretos para seu sistema
```

### Erro: "ffigen failed to generate bindings"

**Verificar:**

1. Header file existe: `native/odbc_engine/include/odbc_engine.h`
2. cbindgen está instalado: `cargo install cbindgen`
3. Clang/LLVM está instalado (Linux): `sudo apt-get install libclang-dev llvm`

### Erro: "cargo build fails with linking errors"

**Linux:**

```bash
sudo apt-get install -y unixodbc unixodbc-dev libclang-dev llvm
```

**Windows:**

- Check that MSVC Toolchain is installed
- `rustup default stable-msvc`

### Build muito lento

**Verificar:**

1. Sanitizers not estão ativos (veja `native/odbc_engine/.cargo/config.toml`)
2. LTO está configurado como "thin" (not "fat")
3. Cache do Cargo está funcionando

### CI/CD failurendo

See [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) for automated pipeline details.

## Recursos Adicionais

- [Rust Book](https://doc.rust-lang.org/book/)
- [Dart FFI](https://dart.dev/guides/libraries/c-interop)
- [ODBC API Reference](https://docs.microsoft.com/en-us/sql/odbc/reference/syntax/odbc-api-reference)
- [Native Assets](https://dart.dev/guides/libraries/native-objects)

## Support

For specific problems:

1. Verifique [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
2. Open an issue on [GitHub](https://github.com/cesar-carlos/dart_odbc_fast/issues)
3. See [api_governance.md](api_governance.md) for versioning policies



