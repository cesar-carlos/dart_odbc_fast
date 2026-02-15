# RELEASE_AUTOMATION.md - Pipeline de Release Automatizado

This document describes the complete ODBC Fast automated release process, including build, publishing to pub.dev, and distribution of binaries via GitHub Releases.

## Índice

- [Visão Geral](#visão-geral)
- [Pipeline Automatizado](#pipeline-automatizado)
- [How to Make a Release](#how-to-make-a-release)
- [Componentes do Pipeline](#componentes-do-pipeline)
- [Troubleshooting](#troubleshooting)
- [Boas Práticas](#boas-práticas)

## Visão Geral

The release process is **100% automated** through GitHub Actions. When creating a versioned tag (e.g. `v0.1.5`), the pipeline:

1. ✅ Compiles the Rust engine for Windows and Linux
2. ✅ Create a release on GitHub with the binaries
3. ✅ Publica no pub.dev (manualmente)
4. ✅ Distribui binários automaticamente via Native Assets

### Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│  1. Desenvolvedor cria tag: git tag v0.1.5                  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  2. GitHub Actions - Release Workflow                       │
│  ├─ Build Windows (x86_64-pc-windows-msvc)                 │
│  │  └─ odbc_engine.dll                                     │
│  ├─ Build Linux (x86_64-unknown-linux-gnu)                 │
│  │  └─ libodbc_engine.so                                   │
│  └─ Cria release no GitHub com binários                    │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  3. Desenvolvedor publica no pub.dev                        │
│  $ dart pub publish                                         │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  4. user instala via pub.dev                            │
│  $ dart pub add odbc_fast:^0.1.5                           │
│                                                             │
│  Hook baixa binário automaticamente:                        │
│  └─ https://github.com/.../releases/download/v0.1.5/...    │
└─────────────────────────────────────────────────────────────┘
```

## Pipeline Automatizado

### GitHub Actions Workflow

**Arquivo**: `.github/workflows/release.yml`

**Trigger**: Push de tag `v*`

**Jobs**:

#### 1. Build Binaries (Matrix)

```yaml
strategy:
  matrix:
    include:
      - os: ubuntu-latest
        target: x86_64-unknown-linux-gnu
        artifact: libodbc_engine.so
      - os: windows-latest
        target: x86_64-pc-windows-msvc
        artifact: odbc_engine.dll
```

**Etapas**:

1. Checkout do código
2. Setup Rust toolchain
3. Cache de dependências Cargo
4. Instalar ODBC (Linux: unixodbc, libclang-dev, llvm)
5. Build do Rust engine
6. Uploading the artifacts

#### 2. Create Release

**Etapas**:

1. Download the artifacts
2. create release no GitHub
3. Upload the binaries (no subdirectories)

### Otimizações de Performance

The pipeline includes several optimizations:

**Cargo Config** (`.cargo/config.toml`):

- ❌ Sanitizers removidos (build 70% mais rápido)
- ✅ Thin LTO (2-3x faster than fat LTO)
- ✅ 16 codegen units (mais paralelismo)
- ✅ Strip=true (binário menor)

**Cache**:

```yaml
- name: Cache Rust dependencies
  uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/registry
      ~/.cargo/git
      native/odbc_engine/target
```

**Resultado**: Build time de 10-15 min → 3-5 min

## How to Make a Release

### Release Oficial (Produção)

#### 1. update version

**Editar `pubspec.yaml`**:

```yaml
name: odbc_fast
version: 0.1.6 # ← Bump version
```

**Editar `CHANGELOG.md`**:

```markdown
## [0.1.6] - 2026-01-27

### Added

- Nova Feature X

### Fixed

- Bug Y corrigido
```

#### 2. Commit e Tag

```bash
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: bump version to 0.1.6"
git push origin main

# create tag
git tag -a v0.1.6 -m "Release v0.1.6"
git push origin v0.1.6
```

#### 3. Aguardar Workflow

**Monitor**: https://github.com/cesar-carlos/dart_odbc_fast/actions

The workflow will:

- Build Windows (3-5 min)
- Build Linux (3-5 min)
- create release no GitHub

#### 4. Publicar no pub.dev

```bash
echo y | dart pub publish
```

#### 5. Verificar Release

**GitHub**: https://github.com/cesar-carlos/dart_odbc/releases/tag/v0.1.6

must conter:

- ✅ `odbc_engine.dll` (Windows)
- ✅ `libodbc_engine.so` (Linux)
- ✅ Release notes

**pub.dev**: https://pub.dev/packages/odbc_fast/versions/0.1.6

### Release de Teste

To test the pipeline without publishing:

```bash
# create tag de teste
git tag -a v0.1.6-test -m "Test release"
git push origin v0.1.6-test

# Monitorar workflow
# not publicar no pub.dev
```

## Componentes do Pipeline

### 1. Native Assets Hook

**Arquivo**: `hook/build.dart`

**Function**: Automatically downloads binaries from GitHub during `dart pub get`

**Fluxo**:

```dart
1. Ler version do pubspec.yaml
2. Determinar OS e Architecture
3. Montar URL: https://github.com/.../releases/download/v{version}/{libName}
4. Baixar binário
5. Salvar em cache: ~/.cache/odbc_fast/
6. returnsr URI para o Dart FFI
```

**Cache Local**:

```
~/.cache/odbc_fast/
├── windows_x86_64/
│   └── odbc_engine.dll
└── linux_x86_64/
    └── libodbc_engine.so
```

### 2. Library Loader

**Arquivo**: `lib/infrastructure/native/bindings/library_loader.dart`

**Function**: Loads the native library with strategic fallback.

**Prioridades** (ordem exata):

1. **Development (workspace)**: `{cwd}/native/target/release/odbc_engine.dll` (or `.so`)
2. **Development (member)**: `{cwd}/native/odbc_engine/target/release/odbc_engine.dll` (or `.so`)
3. **Native Assets (produção)**: `package:odbc_fast/odbc_engine.dll` (asset registrado pelo hook)
4. **Sistema**: PATH (Windows) / LD_LIBRARY_PATH (Linux)

To place the DLL in the correct location in development, see [BUILD.md - Where the DLL must be located](BUILD.md#onde-a-dll-must-be-located-search-order).

### 3. Permissões do Workflow

**Arquivo**: `.github/workflows/release.yml`

```yaml
permissions:
  contents: write # ← Necessário para create releases
```

## Troubleshooting

### Erro: "Pattern 'uploads/\*' does not match any files"

**Cause**: Downloading artifacts with incorrect structure

**Solution**: Check that the workflow uses:

```yaml
- name: Download all artifacts
  uses: actions/download-artifact@v4
  with:
    path: uploads/
    pattern: "*"
    merge-multiple: true # ← Importante!
```

### Error: "GitHub release failed with status: 403"

**Cause**: Workflow without permission to create releases

**Solution**: Add to workflow:

```yaml
permissions:
  contents: write
```

### Build failure with "cp: cannot stat"

**Causa**: Path do binário incorreto (workspace vs member)

**Solution**: Use the workspace path:

```yaml
# Errado (member target)
cp native/odbc_engine/target/${{ matrix.target }}/release/${{ matrix.artifact }}

# Correto (workspace target)
cp native/target/${{ matrix.target }}/release/${{ matrix.artifact }}
```

### Download automático not funciona

**Verificar**:

1. URL de download no hook está correta
2. Arquivos estão na raiz da release (sem subdiretórios)
3. Tag/version correspondem
4. Cache local (`~/.cache/odbc_fast/`)

## Boas Práticas

### SemVer

Siga Semantic Versioning:

- **MAJOR**: Mudanças incompatíveis na API
- **MINOR**: Novas Features compatíveis
- **PATCH**: fixes de bugs

### CHANGELOG

Keep CHANGELOG.md updated:

```markdown
## [0.1.6] - 2026-01-27

### Added

- Novas features

### Changed

- Mudanças compatíveis

### Fixed

- Bugs corrigidos

### Performance

- Otimizações
```

### Testes Antes de Release

```bash
# 1. Testes locais
dart test

# 2. Build manual
cd native && cargo build --release

# 3. Release de teste
git tag v0.1.6-test && git push origin v0.1.6-test

# 4. Validar workflow
# 5. Release oficial
git tag v0.1.6 && git push origin v0.1.6
```

### Rollback

Se algo der errado:

```bash
# Deletar tag local e remota
git tag -d v0.1.6
git push origin :refs/tags/v0.1.6

# Deletar release no GitHub (interface web)

# Publicar fix como v0.1.7
```

## Métricas atuais

- **Build time**: 3-5 minutos (otimizado)
- **Success rate**: ~95%
- **Platforms suportadas**: Windows x86_64, Linux x86_64
- **Binário Windows**: ~1.4 MB
- **pub.dev package**: ~559 KB (with binary included)

## Summary of the version generation process (checklist)

Recommended order to generate a new version (e.g.: 0.3.0):

| #   | Passo                | Comando / Ação                                                                                                                     |
| --- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Testes**           | `dart test --concurrency=1` (todos mustm passar)                                                                                   |
| 2   | **Bump version**      | Editar `pubspec.yaml`: `version: 0.3.0`                                                                                            |
| 3 | **CHANGELOG** | Replace `[Unreleased]` with `[0.3.0] - YYYY-MM-DD`; move items from Unreleased to new section |
| 4   | **README**           | update example de dependência se necessário (ex.: `^0.3.0`)                                                                     |
| 5   | **Dry-run**          | `dart pub publish --dry-run` (validar pacote)                                                                                      |
| 6   | **Commit**           | `git add ...` e `git commit -m "chore: release 0.3.0"` (ou mensagem descritiva)                                                    |
| 7   | **Tag**              | `git tag v0.3.0` (ou `git tag -a v0.3.0 -m "Release v0.3.0"`)                                                                      |
| 8   | **Push**             | `git push origin main` e `git push origin v0.3.0`                                                                                  |
| 9 | **GitHub Release** | Automatic: workflow `.github/workflows/release.yml` runs on tag push; compiles Windows + Linux and creates the release with the binaries |
| 10  | **Publicar pub.dev** | `dart pub publish --force` (confirmar quando solicitado)                                                                           |
| 11  | **Verificar**        | GitHub Releases: binários anexados; pub.dev: version disponível (~10 min)                                                           |

**Observações:**

- The **GitHub Release** is created by the workflow when pushing the tag; create manually in `/releases` is not necessary (unless the workflow fails).
- **Hook / Native Assets**: published package includes `hook/build.dart`; in `dart pub get` the consumer downloads the binary from `https://github.com/.../releases/download/vX.Y.Z/...`.
- For **test release** (without publishing to pub.dev): use a tag like `v0.3.0-rc1` and don't run `dart pub publish`.

## Recursos

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Pub Publishing](https://dart.dev/tools/pub/publishing)
- [Native Assets](https://dart.dev/guides/libraries/native-objects)
- [Semantic Versioning](https://semver.org/)



