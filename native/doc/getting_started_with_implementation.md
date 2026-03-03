# Getting Started - Implementando Novas Features

> **Guia prático** para desenvolvedores que vão implementar features do roadmap  
> **Pré-requisitos**: Conhecimento de Rust, FFI e Dart  
> **Tempo de leitura**: 15 minutos

---

## 🚀 Setup Inicial

### 1. Clone e Build

```bash
# Clone repo
git clone <repo-url>
cd dart_odbc_fast

# Install Rust
rustup update stable

# Install Dart
# (assumindo já instalado)

# Build native engine
cd native/odbc_engine
cargo build --release

# Run tests
cargo test --lib
cargo test --tests

# Run E2E (requer DSN)
ENABLE_E2E_TESTS=1 cargo test --tests -- --ignored
```

### 2. Configure Ambiente

**Arquivo**: `.env` na raiz do projeto

```bash
# ODBC DSN para testes (ou use ODBC_TEST_DB para multi-banco)
ODBC_TEST_DSN=Driver={SQL Server Native Client 11.0};Server=localhost;Database=test;UID=sa;PWD=password;

# Habilitar E2E tests
ENABLE_E2E_TESTS=1

# SQL Server específico (opcional)
SQLSERVER_TEST_SERVER=localhost
SQLSERVER_TEST_DATABASE=test
SQLSERVER_TEST_USER=sa
SQLSERVER_TEST_PASSWORD=password

# Multi-banco: ODBC_TEST_DB=postgres|mysql|sqlite
# ODBC_TEST_DB=sqlite
# SQLITE_TEST_DATABASE=/tmp/odbc_test.db
```

Para PostgreSQL, MySQL e SQLite, veja `native/doc/cross_database.md`.

### 3. Ferramentas Necessárias

```bash
# FFI bindgen
dart pub global activate ffigen

# Code coverage (opcional)
cargo install cargo-tarpaulin

# Benchmarking (já incluído via Criterion)
```

---

## 📚 Estrutura do Projeto

### Arquitetura de Pastas

```
dart_odbc_fast/
├── lib/                          # Dart (cliente)
│   ├── domain/                   # Entities, use cases
│   ├── infrastructure/           # Implementations
│   │   └── native/               # FFI bindings
│   │       ├── bindings/         # Generated bindings
│   │       ├── protocol/         # Binary protocol
│   │       └── wrappers/         # High-level wrappers
│   └── presentation/             # UI (se houver)
│
├── native/                       # Rust (engine)
│   ├── doc/                      # 📚 Documentação (VOCÊ ESTÁ AQUI)
│   │   ├── notes/              # Planos e snapshots arquivados
│   │   ├── notes/
│   │   │   ├── roadmap.md           # Roadmap 2026
│   │   │   ├── action_plan.md       # Checklists executáveis
│   │   │   ├── unexposed_features.md# Features não expostas
│   │   └── ...
│   │
│   └── odbc_engine/             # Crate principal
│       ├── src/
│       │   ├── ffi/             # ⚡ FFI layer (mod.rs)
│       │   ├── engine/          # Core ODBC logic
│       │   │   └── core/        # Executors, pools, etc
│       │   ├── protocol/        # Binary protocol
│       │   ├── pool/            # Connection pooling
│       │   ├── observability/   # Metrics, tracing
│       │   ├── security/        # Sanitization, audit
│       │   ├── handles/         # Handle management
│       │   └── error/           # Error types
│       │
│       ├── tests/               # Integration & E2E tests
│       │   ├── helpers/         # Test utilities
│       │   ├── e2e_*.rs         # E2E tests
│       │   └── *.rs             # Integration tests
│       │
│       ├── benches/             # Benchmarks
│       ├── Cargo.toml           # Dependencies
│       ├── cbindgen.toml        # C header generation
│       └── odbc_exports.def     # Windows exports
│
├── test/                        # Dart tests
└── examples/                    # Exemplos de uso
```

---

## 🎯 Workflow: Adicionando Nova Função FFI

### Exemplo Prático: Implementar `odbc_get_version()`

**Objetivo**: Retornar versão da engine (API + ABI) como JSON.

---

### Step 1: Design da API (15 min)

**Assinatura C**:
```c
int odbc_get_version(
    uint8_t* buffer,
    uint32_t buffer_len,
    uint32_t* out_written
);
```

**Retorno**: JSON
```json
{
  "api_version": "0.1.0",
  "abi_version": "1.0.0",
  "build_date": "2026-03-02",
  "features": ["observability", "test-helpers"]
}
```

**Return codes**:
- `0` = Success
- `-1` = Error (null pointer, lock failed)
- `-2` = Buffer too small

---

### Step 2: Implementar em Rust (30-45 min)

**Arquivo**: `native/odbc_engine/src/ffi/mod.rs`

```rust
/// Get engine version information as JSON.
/// buffer: output buffer for JSON string
/// buffer_len: size of output buffer
/// out_written: bytes written to buffer
/// Returns: 0 on success, -1 on error, -2 if buffer too small
#[no_mangle]
pub extern "C" fn odbc_get_version(
    buffer: *mut u8,
    buffer_len: c_uint,
    out_written: *mut c_uint,
) -> c_int {
    // 1. Validar ponteiros
    if buffer.is_null() || out_written.is_null() {
        return -1;
    }

    if buffer_len == 0 {
        set_out_written_zero(out_written);
        return -1;
    }

    // 2. Construir JSON
    let version_json = serde_json::json!({
        "api_version": env!("CARGO_PKG_VERSION"),
        "abi_version": crate::versioning::abi_version::ABI_VERSION.to_string(),
        "build_date": env!("BUILD_DATE"), // Adicionar em build.rs
        "features": get_enabled_features(),
    });

    let json_str = match serde_json::to_string(&version_json) {
        Ok(s) => s,
        Err(e) => {
            log::error!("Failed to serialize version: {}", e);
            set_out_written_zero(out_written);
            return -1;
        }
    };

    let json_bytes = json_str.as_bytes();

    // 3. Verificar tamanho do buffer
    if json_bytes.len() > buffer_len as usize {
        set_out_written_zero(out_written);
        return -2;
    }

    // 4. Copiar para buffer
    unsafe {
        std::ptr::copy_nonoverlapping(json_bytes.as_ptr(), buffer, json_bytes.len());
        *out_written = json_bytes.len() as c_uint;
    }

    0
}

// Helper: Get enabled cargo features
fn get_enabled_features() -> Vec<&'static str> {
    let mut features = vec![];
    
    #[cfg(feature = "sqlserver-bcp")]
    features.push("sqlserver-bcp");
    
    #[cfg(feature = "observability")]
    features.push("observability");
    
    #[cfg(feature = "test-helpers")]
    features.push("test-helpers");
    
    #[cfg(feature = "ffi-tests")]
    features.push("ffi-tests");
    
    features
}
```

---

### Step 3: Adicionar Export (2 min)

**Arquivo**: `native/odbc_engine/odbc_exports.def`

```diff
EXPORTS
odbc_init
odbc_connect
...
+odbc_get_version
otel_init
...
```

---

### Step 4: Testes Rust (30-45 min)

**Arquivo**: `native/odbc_engine/src/ffi/mod.rs` (seção `#[cfg(test)]`)

```rust
#[test]
fn test_ffi_get_version_success() {
    odbc_init();
    
    let mut buffer = vec![0u8; 1024];
    let mut written: c_uint = 0;
    
    let result = odbc_get_version(
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    
    assert_eq!(result, 0, "Should succeed");
    assert!(written > 0, "Should write data");
    
    let json_str = std::str::from_utf8(&buffer[..written as usize]).unwrap();
    let json: serde_json::Value = serde_json::from_str(json_str).unwrap();
    
    assert!(json["api_version"].is_string());
    assert!(json["abi_version"].is_string());
    assert!(json["features"].is_array());
}

#[test]
fn test_ffi_get_version_null_buffer() {
    let mut written: c_uint = 0;
    let result = odbc_get_version(std::ptr::null_mut(), 1024, &mut written);
    assert_eq!(result, -1);
}

#[test]
fn test_ffi_get_version_null_out_written() {
    let mut buffer = vec![0u8; 1024];
    let result = odbc_get_version(
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        std::ptr::null_mut(),
    );
    assert_eq!(result, -1);
}

#[test]
fn test_ffi_get_version_buffer_too_small() {
    let mut buffer = vec![0u8; 5];
    let mut written: c_uint = 0;
    
    let result = odbc_get_version(
        buffer.as_mut_ptr(),
        buffer.len() as c_uint,
        &mut written,
    );
    
    assert_eq!(result, -2, "Buffer too small");
    assert_eq!(written, 0);
}
```

**Rodar testes**:
```bash
cargo test --lib test_ffi_get_version
```

---

### Step 5: Gerar Bindings Dart (5 min)

**Arquivo**: `ffigen.yaml` (já configurado)

```bash
# Rebuild native
cd native/odbc_engine
cargo build --release

# Generate bindings
cd ../..
dart run ffigen
```

**Output**: `lib/infrastructure/native/bindings/odbc_bindings.dart` (auto-gerado)

---

### Step 6: Wrapper Dart (30-45 min)

**Arquivo**: `lib/infrastructure/native/version/odbc_version.dart` (novo)

```dart
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import '../bindings/odbc_bindings.dart';
import '../exceptions/odbc_exception.dart';

/// Informações de versão da ODBC Engine
class EngineVersion {
  final String apiVersion;
  final String abiVersion;
  final String buildDate;
  final List<String> features;

  const EngineVersion({
    required this.apiVersion,
    required this.abiVersion,
    required this.buildDate,
    required this.features,
  });

  factory EngineVersion.fromJson(Map<String, dynamic> json) {
    return EngineVersion(
      apiVersion: json['api_version'] as String,
      abiVersion: json['abi_version'] as String,
      buildDate: json['build_date'] as String,
      features: (json['features'] as List).cast<String>(),
    );
  }

  @override
  String toString() => 'EngineVersion(api: $apiVersion, abi: $abiVersion)';
}

/// Obtém informações de versão da engine nativa
class OdbcVersionInfo {
  final OdbcBindings _bindings;

  OdbcVersionInfo(this._bindings);

  /// Retorna versão da engine.
  /// 
  /// Throws [OdbcException] em caso de erro.
  EngineVersion getVersion() {
    const bufferSize = 1024;
    final buffer = calloc<ffi.Uint8>(bufferSize);
    final written = calloc<ffi.Uint32>();

    try {
      final result = _bindings.odbc_get_version(
        buffer,
        bufferSize,
        written,
      );

      if (result == -2) {
        throw OdbcException('Buffer too small for version info');
      }

      if (result != 0) {
        throw OdbcException('Failed to get version: error code $result');
      }

      final bytesWritten = written.value;
      if (bytesWritten == 0) {
        throw OdbcException('No version data returned');
      }

      final data = buffer.asTypedList(bytesWritten);
      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;

      return EngineVersion.fromJson(json);
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  }
}
```

---

### Step 7: Testes Dart (30 min)

**Arquivo**: `test/infrastructure/native/version/odbc_version_test.dart` (novo)

```dart
import 'package:dart_odbc_fast/infrastructure/native/bindings/odbc_bindings.dart';
import 'package:dart_odbc_fast/infrastructure/native/version/odbc_version.dart';
import 'package:test/test.dart';
import 'dart:ffi' as ffi;

void main() {
  late OdbcBindings bindings;
  late OdbcVersionInfo versionInfo;

  setUpAll(() {
    final dylib = ffi.DynamicLibrary.open('odbc_engine.dll'); // ou .so/.dylib
    bindings = OdbcBindings(dylib);
    bindings.odbc_init();
    versionInfo = OdbcVersionInfo(bindings);
  });

  group('OdbcVersionInfo', () {
    test('getVersion returns valid version', () {
      final version = versionInfo.getVersion();
      
      expect(version.apiVersion, isNotEmpty);
      expect(version.abiVersion, isNotEmpty);
      expect(version.buildDate, isNotEmpty);
      expect(version.features, isA<List<String>>());
    });

    test('getVersion returns consistent data', () {
      final v1 = versionInfo.getVersion();
      final v2 = versionInfo.getVersion();
      
      expect(v1.apiVersion, equals(v2.apiVersion));
      expect(v1.abiVersion, equals(v2.abiVersion));
    });

    test('getVersion includes expected features', () {
      final version = versionInfo.getVersion();
      
      // Assume observability está habilitado por padrão
      expect(version.features, contains('observability'));
    });
  });
}
```

**Rodar testes**:
```bash
dart test test/infrastructure/native/version/
```

---

### Step 8: Documentação (15-30 min)

**Atualizar**: `native/doc/ffi_api.md`

```markdown
## Version Information

### `odbc_get_version`

Get engine version information.

**Signature**:
```c
int odbc_get_version(
    uint8_t* buffer,
    uint32_t buffer_len,
    uint32_t* out_written
);
```

**Parameters**:
- `buffer`: Output buffer for JSON string
- `buffer_len`: Size of output buffer (recommend 1024 bytes)
- `out_written`: Pointer to receive bytes written

**Returns**:
- `0`: Success
- `-1`: Error (null pointer, internal error)
- `-2`: Buffer too small

**Output Format** (JSON):
```json
{
  "api_version": "0.1.0",
  "abi_version": "1.0.0",
  "build_date": "2026-03-02",
  "features": ["observability", "test-helpers"]
}
```

**Example (C)**:
```c
char buffer[1024];
uint32_t written;
int result = odbc_get_version((uint8_t*)buffer, sizeof(buffer), &written);
if (result == 0) {
    printf("Version: %.*s\n", written, buffer);
}
```

**Example (Dart)**:
```dart
final versionInfo = OdbcVersionInfo(bindings);
final version = versionInfo.getVersion();
print('API: ${version.apiVersion}');
print('ABI: ${version.abiVersion}');
```
```

---

### Step 9: Update CHANGELOG (5 min)

**Arquivo**: `CHANGELOG.md`

```markdown
## [Unreleased]

### Added
- `odbc_get_version()` - Get engine version information as JSON

### Changed
- (list changes)

### Fixed
- (list fixes)
```

---

### Step 10: Code Review e Merge (variável)

**Checklist pré-PR**:
- [ ] `cargo fmt`
- [ ] `cargo clippy --all-targets --all-features`
- [ ] `cargo test --lib` passa
- [ ] `cargo test --tests` passa (se aplicável)
- [ ] `dart test` passa
- [ ] Documentação atualizada
- [ ] CHANGELOG atualizado
- [ ] Self-review do código

**Criar PR**:
```bash
git checkout -b feature/odbc-get-version
git add .
git commit -m "feat: add odbc_get_version FFI function

- Implements FFI function to return version info as JSON
- Adds Dart wrapper OdbcVersionInfo
- Includes comprehensive tests (Rust + Dart)
- Updates documentation"
git push origin feature/odbc-get-version
```

---

## 🔧 Ferramentas de Desenvolvimento

### Comandos Úteis

#### Build e Test Rápido
```bash
# Build debug (rápido)
cargo build

# Build release (otimizado)
cargo build --release

# Test específico
cargo test --lib nome_do_teste

# Test com output
cargo test --lib nome_do_teste -- --nocapture

# Test E2E
ENABLE_E2E_TESTS=1 cargo test --test nome_arquivo -- --ignored
```

#### Code Quality
```bash
# Format código
cargo fmt

# Lint
cargo clippy --all-targets --all-features

# Lint rigoroso
cargo clippy --all-targets --all-features -- -D warnings

# Check sem build
cargo check
```

#### Benchmarking
```bash
# Run all benchmarks
cargo bench

# Run específico
cargo bench nome_benchmark

# Com output detalhado
cargo bench -- --verbose
```

#### Coverage
```bash
# Gerar relatório de coverage (requer cargo-tarpaulin)
cargo tarpaulin --out Html --output-dir target/coverage
```

---

## 📝 Convenções de Código

### Rust

**Naming**:
- Structs: `PascalCase`
- Functions: `snake_case`
- Constants: `SCREAMING_SNAKE_CASE` (mas preferir `lower_case` quando possível)
- Modules: `snake_case`

**FFI Functions**:
- Sempre `pub extern "C"`
- Sempre `#[no_mangle]`
- Prefixo `odbc_` para funções principais
- Prefixo `otel_` para observability
- Return code: `c_int` (`0` = success, `-1` = error, `-2` = buffer too small)
- IDs: `c_uint` (sempre `> 0`, `0` = invalid/error)

**Error Handling**:
```rust
// ✅ Bom: Result com context
conn.execute(sql).map_err(|e| OdbcError::QueryFailed(format!("Failed: {}", e)))?

// ❌ Evitar: unwrap/expect em runtime
state.lock().unwrap() // ← NUNCA em código FFI

// ✅ Correto: Handle poisoning
state.lock().unwrap_or_else(|e| e.into_inner())
```

### Dart

**Naming**:
- Classes: `PascalCase`
- Methods: `camelCase`
- Constants: `camelCase` (ou `lowerCamelCase`)
- Files: `snake_case.dart`

**FFI Patterns**:
```dart
// ✅ Sempre use try-finally para cleanup
final buffer = calloc<ffi.Uint8>(size);
try {
  // Use buffer
} finally {
  calloc.free(buffer);
}

// ✅ Validar return codes
final result = bindings.some_function(...);
if (result != 0) {
  throw OdbcException('Error: code $result');
}

// ✅ Converter tipos C → Dart
final cString = buffer.cast<Utf8>();
final dartString = cString.toDartString();
```

---

## 🎯 Melhores Práticas

### FFI Performance

**DO** ✅:
```rust
// Minimize locks
let data = {
    let state = lock_state()?;
    state.get_data()  // Release lock imediatamente
};
process(data);

// Use wrapping_add para IDs
self.next_id = self.next_id.wrapping_add(1);

// Buffer size razoável
const BUFFER_SIZE: usize = 4096; // 4KB
```

**DON'T** ❌:
```rust
// Lock prolongado
let state = lock_state()?;
let data = state.get_data();
expensive_operation(&data);  // ← Lock ainda ativo!
state.set_data(result);

// Panic em runtime
state.lock().unwrap()  // ← Pode panic!

// Magic numbers
if buffer.len() > 1234 { ... }  // ← Use const!
```

### Testing

**Estrutura de Test**:
```rust
#[test]
fn test_feature_success_case() {
    // Arrange
    let input = setup_test_data();
    
    // Act
    let result = function_under_test(input);
    
    // Assert
    assert_eq!(result, expected);
}
```

**E2E Test Pattern**:
```rust
#[test]
fn test_e2e_feature() {
    // Skip se DSN não configurado
    if !should_run_e2e_tests() {
        eprintln!("⚠️  Skipping: ODBC_TEST_DSN not set");
        return;
    }
    
    // Setup
    let conn_str = get_sqlserver_test_dsn().unwrap();
    
    // Test
    // ...
    
    // Cleanup
}
```

---

## 🔍 Debugging

### Rust Debugging

**Enable logs**:
```bash
# Set log level
export RUST_LOG=debug

# Run com logs
cargo test -- --nocapture
```

**Print debugging**:
```rust
// Use log macros
log::debug!("Value: {:?}", value);
log::info!("Processing...");
log::error!("Failed: {}", error);

// Em testes, use eprintln!
eprintln!("Debug: {:?}", state);
```

**Debugger**:
```bash
# VS Code: Add breakpoint e F5
# CLI: rust-lldb (macOS/Linux) ou rust-gdb (Linux)
```

### Dart Debugging

**Print debugging**:
```dart
import 'dart:developer' as developer;

developer.log('Debug info', name: 'odbc.native');
```

**Debugger**: VS Code com Dart extension.

---

## 🚨 Troubleshooting Comum

### Problema 1: "Symbol not found" ao rodar Dart

**Causa**: Export não adicionado em `odbc_exports.def`.

**Fix**:
```diff
+odbc_nova_funcao
```

Rebuild: `cargo build --release`

---

### Problema 2: Tests FFI falham com "lock poisoned"

**Causa**: Test anterior panicked.

**Fix**:
```bash
# Run serialmente
cargo test --lib -- --test-threads=1
```

Ou corrigir test isolation:
```rust
.lock().unwrap_or_else(|e| e.into_inner())
```

---

### Problema 3: Dart test não encontra biblioteca

**Causa**: Path da biblioteca incorreto.

**Fix**:
```dart
// Windows
final dylib = ffi.DynamicLibrary.open('target/release/odbc_engine.dll');

// Linux
final dylib = ffi.DynamicLibrary.open('target/release/libodbc_engine.so');

// macOS
final dylib = ffi.DynamicLibrary.open('target/release/libodbc_engine.dylib');
```

---

### Problema 4: E2E tests não rodam

**Causa**: DSN não configurado ou `ENABLE_E2E_TESTS` não setado.

**Fix**:
```bash
# Set environment
export ENABLE_E2E_TESTS=1
export ODBC_TEST_DSN="Driver={SQL Server};Server=localhost;..."

# Or use .env file (na raiz do projeto)
```

---

## 📚 Recursos e Referências

### Documentação Interna

- [`ffi_api.md`](./ffi_api.md) - Referência completa de todas as 47 funções FFI
- [`ffi_conventions.md`](./ffi_conventions.md) - Padrões de return codes, IDs, buffers
- [`data_paths.md`](./data_paths.md) - Como dados fluem internamente
- [`cross_database.md`](./cross_database.md) - Connection strings, quirks, multi-banco
- [`performance_comparison.md`](./performance_comparison.md) - Benchmarks e recomendações
- [`unexposed_features.md`](./notes/unexposed_features.md) - Features prontas para expor

### Documentação Externa

- [Rust FFI Book](https://doc.rust-lang.org/nomicon/ffi.html)
- [Dart FFI Guide](https://dart.dev/guides/libraries/c-interop)
- [ODBC API Reference](https://docs.microsoft.com/en-us/sql/odbc/reference/syntax/odbc-api-reference)
- [odbc-api crate docs](https://docs.rs/odbc-api)

### Exemplos de Código

- `native/odbc_engine/src/ffi/mod.rs` - Todas as funções FFI existentes
- `lib/infrastructure/native/` - Wrappers Dart existentes
- `examples/` - Exemplos completos de uso

### Exemplo Rápido: Audit Logger

```dart
final locator = ServiceLocator();
locator.initialize();

final audit = locator.auditLogger;
audit.enable();

final status = audit.getStatus();
print('audit enabled=${status?.enabled} events=${status?.eventCount}');

final events = audit.getEvents(limit: 20);
print('events=${events.length}');

audit.clear();
```

> Observação: em ambientes com lib nativa antiga, a API de audit pode não estar
> disponível. Nesse caso, chamadas de audit podem retornar `null`/`false`.

### Exemplo Rápido: Audit Logger (Async)

```dart
final locator = ServiceLocator();
locator.initialize(useAsync: true);

final audit = locator.asyncAuditLogger;
await audit.enable();

final status = await audit.getStatus();
print('audit enabled=${status?.enabled} events=${status?.eventCount}');

final events = await audit.getEvents(limit: 20);
print('events=${events.length}');

await audit.clear();
```

---

## 🎯 Checklist: "Estou Pronto para Começar"

Antes de começar a implementar, verifique:

- [ ] **Ambiente**:
  - [ ] Rust stable instalado
  - [ ] Dart SDK instalado
  - [ ] VS Code com extensions (Rust Analyzer, Dart)
  - [ ] DSN ODBC configurado (para E2E)
  - [ ] `.env` file configurado

- [ ] **Build Funciona**:
  - [ ] `cargo build --release` compila sem erros
  - [ ] `cargo test --lib` passa
  - [ ] `dart test` passa (pelo menos os não-FFI)

- [ ] **Documentação Lida**:
  - [ ] Li `notes/roadmap.md` (snapshot atual e visão geral)
  - [ ] Li `notes/action_plan.md` (minha feature específica)
  - [ ] Li `ffi_conventions.md` (padrões)

- [ ] **Feature Escolhida**:
  - [ ] Tenho task assignment clara
  - [ ] Entendo requisitos
  - [ ] Estimativa de esforço revisada
  - [ ] Critérios de aceite claros

---

## 🚦 Workflow Git

### Branch Naming

```
feature/[feature-name]     # Nova feature
fix/[bug-name]            # Bug fix
refactor/[area]           # Refactoring
docs/[topic]              # Documentation
test/[test-area]          # Test improvements
```

### Commit Messages

**Formato**: `type(scope): subject`

**Types**:
- `feat`: Nova feature
- `fix`: Bug fix
- `refactor`: Refactoring
- `test`: Adicionar/melhorar testes
- `docs`: Documentação
- `perf`: Performance improvement
- `chore`: Manutenção

**Exemplos**:
```
feat(ffi): add odbc_get_version function
fix(pool): prevent connection leak on error
test(batch): add regression test for parameter binding
docs(api): update ffi_api.md with new functions
perf(streaming): reduce memory allocation in batched mode
```

---

## 🎯 Quick Start: Sua Primeira Feature

### Recomendação: Comece com um Quick Win!

**Feature Sugerida**: `odbc_get_version()` (explicada acima)

**Por quê**:
- ✅ Simples (2-3 horas)
- ✅ Toca todos os layers (Rust FFI + Dart)
- ✅ Não requer DSN
- ✅ Útil para debug

**Passos**:
1. Siga Step 1-10 acima
2. Teste localmente
3. Crie PR
4. Iterate com feedback

**Success**: ✅ Você implementou sua primeira feature FFI completa!

---

## 💡 Dicas Profissionais

### 1. Comece Pequeno
Não tente implementar Async API inteira de uma vez. Quebre em funções menores.

### 2. Teste Incrementalmente
Escreva testes conforme implementa, não depois.

### 3. Use Templates
Copie padrões de código existente em `ffi/mod.rs`.

### 4. Documente Enquanto Coda
Não deixe docs para depois.

### 5. Peça Review Cedo
PR pequenos são mais fáceis de revisar.

### 6. Automatize
Use scripts para tasks repetitivas (build + test + fmt).

### 7. Profile Primeiro
Benchmark antes de otimizar.

### 8. Mantenha Compatibilidade
Nunca quebre API existente sem versioning.

---

## 🎯 Conclusão

Você agora tem:

1. ✅ **Ambiente configurado** corretamente
2. ✅ **Entendimento da estrutura** do projeto
3. ✅ **Workflow completo** (design → implementação → teste → doc → PR)
4. ✅ **Exemplo prático** (`odbc_get_version`)
5. ✅ **Convenções e padrões** claros
6. ✅ **Troubleshooting guide** para problemas comuns
7. ✅ **Recursos e referências** organizados

### Próximos Passos

1. **Escolha uma feature** do `notes/action_plan.md`
2. **Leia a spec detalhada** na seção correspondente
3. **Implemente seguindo o workflow** acima
4. **Teste extensivamente**
5. **Documente bem**
6. **Crie PR para review**

### Need Help?

- 📖 Consulte [`action_plan.md`](./notes/action_plan.md) para checklists detalhados
- 📖 Consulte [`ffi_api.md`](./ffi_api.md) para exemplos de código
- 📖 Consulte [`cross_database.md`](./cross_database.md) para setup multi-banco
- 📖 Consulte [`unexposed_features.md`](./notes/unexposed_features.md) para features prontas

---

**Boa sorte! 🚀**

**Dúvidas?** Consulte a documentação ou peça help no code review.

---

**Última atualização**: 2026-03-03  
**Autor**: ODBC Fast Team  
**Feedback**: Bem-vindo! Melhore este doc conforme aprende.
