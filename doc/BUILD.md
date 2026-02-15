# BUILD.md - Build e desenvolvimento

Guia objetivo para preparar o ambiente, compilar o engine Rust e validar o pacote Dart.

## Pre-requisitos

### Windows

```powershell
winget install Rustlang.Rust.MSVC
winget install Google.DartSDK
```

- ODBC Driver Manager ja vem no Windows.

### Linux (Ubuntu/Debian)

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo apt-get update
sudo apt-get install -y dart unixodbc unixodbc-dev libclang-dev llvm
```

## Build local (fluxo recomendado)

Na raiz do repositorio:

```bash
cd native
cargo build --release
```

Saida esperada:

- Windows: `native/target/release/odbc_engine.dll`
- Linux: `native/target/release/libodbc_engine.so`

## Ordem de busca da biblioteca nativa

`library_loader.dart` tenta carregar nesta ordem:

1. `native/target/release/<lib>` (workspace)
2. `native/odbc_engine/target/release/<lib>` (build no membro)
3. `package:odbc_fast/<lib>` (Native Assets)
4. PATH/LD_LIBRARY_PATH

Dica: usar sempre `cd native && cargo build --release` evita copia manual de DLL/.so.

## Copia manual (somente quando necessario)

### Windows

```powershell
New-Item -ItemType Directory -Force -Path "native\target\release" | Out-Null
Copy-Item "native\odbc_engine\target\release\odbc_engine.dll" "native\target\release\odbc_engine.dll" -Force
```

### Linux

```bash
mkdir -p native/target/release
cp native/odbc_engine/target/release/libodbc_engine.so native/target/release/
```

## Bindings FFI (opcional)

Os bindings sao mantidos no repo. Regenerar apenas quando a surface C mudar:

```bash
dart run ffigen -v info
```

Arquivo de configuracao: `ffigen.yaml`

## Testes

```bash
dart test
```

Suites uteis:

```bash
dart test test/domain/
dart test test/infrastructure/native/
dart test test/integration/
```

Observacao: parte dos testes de integracao depende de DSN real (`ODBC_TEST_DSN`).

Para incluir os 10 testes normalmente ignorados (slow, stress, native-assets):

```bash
RUN_SKIPPED_TESTS=1 dart test
```

Ou no PowerShell: `$env:RUN_SKIPPED_TESTS='1'; dart test`. Aceita `1`, `true`, `yes`.

## Troubleshooting relacionado

- Erros de biblioteca nao encontrada: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- Erros de release/tag/workflow: [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)
- Politica de versao: [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)
