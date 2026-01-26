# BUILD.md - Guia de Build e Desenvolvimento

Este guia cobre o processo completo de build e desenvolvimento do ODBC Fast, incluindo o Rust native engine, bindings FFI do Dart, e configuração do ambiente.

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Configuração do Ambiente](#configuração-do-ambiente)
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

## Estrutura do Projeto

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
│   └── odbc_engine/             # Membro do workspace
│       ├── Cargo.toml
│       ├── build.rs             # Build script (cbindgen)
│       ├── .cargo/config.toml   # Configuração do Cargo
│       └── src/
├── hook/                        # Native Assets hooks
│   └── build.dart               # Hook de build automático
├── ffigen.yaml                  # Configuração do ffigen
└── pubspec.yaml                 # Dependências Dart
```

## Configuração do Ambiente

### 1. Clonar o Repositório

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

O binário será criado em:
- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

### Build com Cross-Compilation

```bash
# Windows (no Linux)
cargo build --release --target x86_64-pc-windows-msvc

# Linux (no Windows)
cargo build --release --target x86_64-unknown-linux-gnu
```

## Gerar Bindings FFI

Os bindings FFI são gerados automaticamente pelo hook, mas podem ser gerados manualmente:

```bash
# A partir da raiz do projeto
dart run ffigen -v info
```

O arquivo gerado será: `lib/infrastructure/native/bindings/odbc_bindings.dart`

### Configuração do ffigen

```yaml
# ffigen.yaml
output: 'lib/infrastructure/native/bindings/odbc_bindings.dart'
headers:
  - 'native/odbc_engine/include/odbc_engine.h'
header-comments: false
functions:
  include:
    - 'Odbc.*'
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

3. **Testar com Dart**
   ```bash
   dart test
   ```

### Testes

**Todos os testes:**
```bash
dart test
```

**Testes específicos:**
```bash
# Testes de validação
dart test test/validation/

# Testes de integração (requer DSN configurado)
dart test test/integration/

# Testes de stress
dart test test/stress/
```

## Performance

### Otimizações Ativas

O projeto usa várias otimizações para build time e runtime:

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
- **Pooling**: Pool de conexões reutilizáveis
- **Protocolo binário**: Transferência eficiente de dados
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
- Verifique que o MSVC Toolchain está instalado
- `rustup default stable-msvc`

### Build muito lento

**Verificar:**
1. Sanitizers não estão ativos (veja `native/odbc_engine/.cargo/config.toml`)
2. LTO está configurado como "thin" (não "fat")
3. Cache do Cargo está funcionando

### CI/CD falhando

Veja [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) para detalhes do pipeline automatizado.

## Recursos Adicionais

- [Rust Book](https://doc.rust-lang.org/book/)
- [Dart FFI](https://dart.dev/guides/libraries/c-interop)
- [ODBC API Reference](https://docs.microsoft.com/en-us/sql/odbc/reference/syntax/odbc-api-reference)
- [Native Assets](https://dart.dev/guides/libraries/native-objects)

## Suporte

Para problemas específicos:
1. Verifique [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
2. Abra uma issue no [GitHub](https://github.com/cesar-carlos/dart_odbc_fast/issues)
3. Consulte [api_governance.md](api_governance.md) para políticas de versionamento
