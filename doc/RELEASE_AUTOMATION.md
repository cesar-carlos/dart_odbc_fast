# RELEASE_AUTOMATION.md - Pipeline de Release Automatizado

Este documento descreve o processo completo de release automatizado do ODBC Fast, incluindo build, publicação no pub.dev e distribuição de binários via GitHub Releases.

## Índice

- [Visão Geral](#visão-geral)
- [Pipeline Automatizado](#pipeline-automatizado)
- [Como Fazer um Release](#como-fazer-um-release)
- [Componentes do Pipeline](#componentes-do-pipeline)
- [Troubleshooting](#troubleshooting)
- [Boas Práticas](#boas-práticas)

## Visão Geral

O processo de release é **100% automatizado** através de GitHub Actions. Ao criar uma tag versionada (ex: `v0.1.5`), o pipeline:

1. ✅ Compila o Rust engine para Windows e Linux
2. ✅ Cria uma release no GitHub com os binários
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
│  4. Usuário instala via pub.dev                            │
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
6. Upload dos artefatos

#### 2. Create Release

**Etapas**:
1. Download dos artefatos
2. Criar release no GitHub
3. Upload dos binários (sem subdiretórios)

### Otimizações de Performance

O pipeline inclui várias otimizações:

**Cargo Config** (`.cargo/config.toml`):
- ❌ Sanitizers removidos (build 70% mais rápido)
- ✅ Thin LTO (2-3x mais rápido que fat LTO)
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

## Como Fazer um Release

### Release Oficial (Produção)

#### 1. Atualizar Versão

**Editar `pubspec.yaml`**:
```yaml
name: odbc_fast
version: 0.1.6  # ← Bump version
```

**Editar `CHANGELOG.md`**:
```markdown
## [0.1.6] - 2026-01-27

### Added
- Nova funcionalidade X

### Fixed
- Bug Y corrigido
```

#### 2. Commit e Tag

```bash
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: bump version to 0.1.6"
git push origin main

# Criar tag
git tag -a v0.1.6 -m "Release v0.1.6"
git push origin v0.1.6
```

#### 3. Aguardar Workflow

**Monitorar**: https://github.com/cesar-carlos/dart_odbc_fast/actions

O workflow irá:
- Build Windows (3-5 min)
- Build Linux (3-5 min)
- Criar release no GitHub

#### 4. Publicar no pub.dev

```bash
echo y | dart pub publish
```

#### 5. Verificar Release

**GitHub**: https://github.com/cesar-carlos/dart_odbc/releases/tag/v0.1.6

Deve conter:
- ✅ `odbc_engine.dll` (Windows)
- ✅ `libodbc_engine.so` (Linux)
- ✅ Release notes

**pub.dev**: https://pub.dev/packages/odbc_fast/versions/0.1.6

### Release de Teste

Para testar o pipeline sem publicar:

```bash
# Criar tag de teste
git tag -a v0.1.6-test -m "Test release"
git push origin v0.1.6-test

# Monitorar workflow
# NÃO publicar no pub.dev
```

## Componentes do Pipeline

### 1. Native Assets Hook

**Arquivo**: `hook/build.dart`

**Função**: Baixa automaticamente os binários do GitHub durante `dart pub get`

**Fluxo**:
```dart
1. Ler versão do pubspec.yaml
2. Determinar OS e Architecture
3. Montar URL: https://github.com/.../releases/download/v{version}/{libName}
4. Baixar binário
5. Salvar em cache: ~/.cache/odbc_fast/
6. Retornar URI para o Dart FFI
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

**Função**: Carrega a biblioteca nativa com fallback estratégico

**Prioridades**:
1. Native Assets (produção)
2. Caminhos de desenvolvimento local
3. System PATH

### 3. Permissões do Workflow

**Arquivo**: `.github/workflows/release.yml`

```yaml
permissions:
  contents: write  # ← Necessário para criar releases
```

## Troubleshooting

### Erro: "Pattern 'uploads/*' does not match any files"

**Causa**: Download de artifacts com estrutura incorreta

**Solução**: Verifique que o workflow usa:
```yaml
- name: Download all artifacts
  uses: actions/download-artifact@v4
  with:
    path: uploads/
    pattern: '*'
    merge-multiple: true  # ← Importante!
```

### Erro: "GitHub release failed with status: 403"

**Causa**: Workflow sem permissão para criar releases

**Solução**: Adicione ao workflow:
```yaml
permissions:
  contents: write
```

### Build falha com "cp: cannot stat"

**Causa**: Path do binário incorreto (workspace vs member)

**Solução**: Use o path do workspace:
```yaml
# Errado (member target)
cp native/odbc_engine/target/${{ matrix.target }}/release/${{ matrix.artifact }}

# Correto (workspace target)
cp native/target/${{ matrix.target }}/release/${{ matrix.artifact }}
```

### Download automático não funciona

**Verificar**:
1. URL de download no hook está correta
2. Arquivos estão na raiz da release (sem subdiretórios)
3. Tag/versão correspondem
4. Cache local (`~/.cache/odbc_fast/`)

## Boas Práticas

### SemVer

Siga Semantic Versioning:
- **MAJOR**: Mudanças incompatíveis na API
- **MINOR**: Novas funcionalidades compatíveis
- **PATCH**: Correções de bugs

### CHANGELOG

Mantenha o CHANGELOG.md atualizado:
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

# Publicar correção como v0.1.7
```

## Métricas atuais

- **Build time**: 3-5 minutos (otimizado)
- **Success rate**: ~95%
- **Platforms suportadas**: Windows x86_64, Linux x86_64
- **Binário Windows**: ~1.4 MB
- **Pacote pub.dev**: ~559 KB (com binário incluso)

## Recursos

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Pub Publishing](https://dart.dev/tools/pub/publishing)
- [Native Assets](https://dart.dev/guides/libraries/native-objects)
- [Semantic Versioning](https://semver.org/)
