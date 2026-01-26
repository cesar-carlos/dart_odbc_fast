# TROUBLESHOOTING.md - Solução de Problemas

Este documento cobre problemas comuns e suas soluções para desenvolvimento, build e deploy do ODBC Fast.

## Índice

- [Desenvolvimento Local](#desenvolvimento-local)
- [Build e Compilação](#build-e-compilação)
- [FFI e Bindings](#ffi-e-bindings)
- [Runtime e Execução](#runtime-e-execução)
- [CI/CD e Releases](#cicd-e-releases)
- [ODBC e Conexões](#odbc-e-conexões)

## Desenvolvimento Local

### Dart pub get falha

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

### Testes falham com "odbc_engine.dll not found"

**Sintoma**:
```
StateError: ODBC engine library not found
```

**Causa**: Binário Rust não foi compilado

**Solução**:
```bash
cd native
cargo build --release

# Verificar que o binário existe
ls target/release/odbc_engine.dll  # Windows
ls target/release/libodbc_engine.so  # Linux
```

### Ffigen não gera bindings

**Sintoma**:
```
ffigen failed to generate bindings
```

**Causas possíveis**:

1. **Header file não existe**:
```bash
# Verificar
ls native/odbc_engine/include/odbc_engine.h

# Se não existir, buildar o Rust primeiro
cd native/odbc_engine
cargo build
```

2. **Clang/LLVM não instalado (Linux)**:
```bash
sudo apt-get install -y libclang-dev llvm
```

3. **Configuração incorreta do ffigen.yaml**:
```yaml
output: 'lib/infrastructure/native/bindings/odbc_bindings.dart'
headers:
  - 'native/odbc_engine/include/odbc_engine.h'
```

## Build e Compilação

### Cargo build muito lento

**Sintoma**: Build demora mais de 10 minutos

**Causa**: Sanitizers ativos

**Verificar**:
```bash
# native/odbc_engine/.cargo/config.toml
# Remover se existir:
[target.x86_64-unknown-linux-gnu]
rustflags = [
    "-C", "link-arg=-fsanitize=address",
    "-C", "link-arg=-fsanitize=undefined",
]
```

**Resultado esperado**: Build time de 3-5 minutos

### Cross-compilation falha

**Sintoma**:
```
error: linker `x86_64-w64-mingw32-gcc` not found
```

**Solução (Linux → Windows)**:
```bash
sudo apt-get install -y mingw-w64
rustup target add x86_64-pc-windows-msvc
```

### ODBC headers não encontrados

**Sintoma** (Linux):
```
fatal error: sql.h: No such file or directory
```

**Solução**:
```bash
sudo apt-get install -y unixodbc unixodbc-dev
```

### cbindgen falha

**Sintoma**:
```
error: failed to run custom build command for `odbc_engine`
```

**Causa**: build.rs executando cbindgen falhou

**Solução**:
```bash
# Instalar cbindgen
cargo install cbindgen

# Verificar configuração
cat native/odbc_engine/cbindgen.toml
```

## FFI e Bindings

### "Invalid function pointer" ao chamar funções nativas

**Sintoma**:
```
Invalid argument(s): Invalid function pointer
```

**Causa**: Bindings desincronizados com o header

**Solução**:
```bash
# Regenerar bindings
dart run ffigen -v info

# Verificar que a versão do binário corresponde
cd native && cargo build --release
```

### Segmentation fault ao chamar função nativa

**Sintoma**: Processo Dart crasha

**Causas possíveis**:

1. **Mismatch entre Dart e Rust ABI**:
```bash
# Verificar que está usando a versão correta do binário
rm ~/.cache/odbc_fast/* -rf
dart pub get
```

2. **Memory corruption no Rust**:
```bash
# Rodar com sanitizers (development)
cd native/odbc_engine
RUSTFLAGS="-Z sanitizer=address" cargo test
```

3. **Types incorretos nos bindings**:
```dart
// Verificar que o tipo no binding corresponde ao Rust
// Ex: IntPtr vs int vs Pointer<Void>
```

## Runtime e Execução

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

**Causa**: Result sets não sendo liberados

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

### Pool de conexões esgotado

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

// Ou garantir que conexões são liberadas
try {
  final conn = await service.poolGetConnection();
  // Usar conexão
} finally {
  await service.poolReleaseConnection(conn);
}
```

## CI/CD e Releases

### GitHub Actions workflow falha com "cp: cannot stat"

**Sintoma** (workflow):
```
cp: cannot stat 'native/odbc_engine/target/.../libodbc_engine.so'
```

**Causa**: Workspace Cargo cria binário em `native/target/`, não `native/odbc_engine/target/`

**Solução**:
```yaml
# .github/workflows/release.yml
- name: Rename artifact
  run: |
    mkdir -p uploads
    cp native/target/${{ matrix.target }}/release/${{ matrix.artifact }} \
       uploads/${{ matrix.artifact }}
```

### Release workflow retorna 403 Forbidden

**Sintoma**:
```
GitHub release failed with status: 403
```

**Causa**: Workflow sem permissão para criar releases

**Solução**:
```yaml
# .github/workflows/release.yml
permissions:
  contents: write  # ← Adicionar
```

### "Pattern 'uploads/*' does not match any files"

**Sintoma** (release workflow):
```
Pattern 'uploads/*' does not match any files
```

**Causa**: Artifacts são baixados com subdiretório

**Solução**:
```yaml
- name: Download all artifacts
  uses: actions/download-artifact@v4
  with:
    path: uploads/
    pattern: '*'
    merge-multiple: true  # ← Importante
```

### Download automático não funciona

**Sintoma**: `dart pub get` não baixa o binário

**Verificar**:

1. **URL está correta** (hook/build.dart):
```dart
final url = 'https://github.com/cesar-carlos/dart_odbc_fast'
    '/releases/download/v$version/$libName';
```

2. **Arquivos existem na release**:
```bash
# Verificar no GitHub que os arquivos estão na RAIZ
# Não em: uploads/odbc_engine.dll
# Deve ser: odbc_engine.dll
```

3. **Versão corresponde**:
```bash
# pubspec.yaml version deve corresponder à tag no GitHub
version: 0.1.5  # → v0.1.5
```

### ffigen no CI falha com "--verbose"

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

## ODBC e Conexões

### "Driver not found" no Windows

**Sintoma**:
```
IM002 [Microsoft][ODBC Driver Manager] Data source name not found
```

**Solução**:

1. **Instalar o driver ODBC correto**:
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

### Conexão cai após alguns minutos

**Sintoma**: `OdbcError.connectionLost` após tempo

**Causa**: Timeout de conexão ou firewall

**Solução**:
```dart
// Usar pooling com health check
await service.poolCreate(
  connectionString,
  maxConnections: 10,
);

// Pool valida conexões automaticamente
final conn = await service.poolGetConnection();
// Conexão é validada antes de ser retornada
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

Se você não conseguiu resolver seu problema:

1. **Verifique a documentação**:
   - [BUILD.md](BUILD.md) - Build e desenvolvimento
   - [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) - Pipeline de releases
   - [README.md](../README.md) - Visão geral

2. **Search issues existentes**:
   https://github.com/cesar-carlos/dart_odbc_fast/issues

3. **Criar nova issue**:
   - Descreva o problema detalhadamente
   - Inclua mensagens de erro completas
   - Informe seu sistema operacional e versões
   - Forneça steps para reproduzir

4. **Logs úteis para incluir**:
   - `dart --version`
   - `rustc --version`
   - Output completo do erro
   - Arquivo de configuração (sem credenciais)
