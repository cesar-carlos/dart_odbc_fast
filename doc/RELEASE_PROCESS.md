# Release Process

## Overview

Este documento descreve o processo completo para criar uma nova release do `odbc_fast`.

## Pré-requisitos

- [ ] Todos os testes passando (`dart test`)
- [ ] Lint limpo (`dart analyze`)
- [ ] Workflows do GitHub Actions passando (CI e M1 Validation)
- [ ] CHANGELOG.md atualizado com as mudanças da versão
- [ ] Versão no `pubspec.yaml` atualizada

## Processo de Release

### 1. Preparação

#### 1.1 Atualizar versão no pubspec.yaml

```yaml
name: odbc_fast
version: 0.1.0  # Atualizar esta linha
```

#### 1.2 Atualizar CHANGELOG.md

Adicionar nova seção com a data atual:

```markdown
## [0.1.0] - 2026-01-26

### Added
- Feature 1
- Feature 2

### Fixed
- Bug 1

### Changed
- Change 1
```

#### 1.3 Validar localmente

```bash
# Lint
dart analyze

# Testes
dart test

# Build Rust (opcional, mas recomendado)
cd native/odbc_engine
cargo build --release
cd ../..

# Dry-run de publicação
dart pub publish --dry-run
```

#### 1.4 Commit das mudanças

```bash
git add .
git commit -m "chore: prepare release v0.1.0"
git push origin main
```

### 2. Criar Tag

#### 2.1 Criar tag localmente

```bash
# Criar tag anotada
git tag -a v0.1.0 -m "Release v0.1.0 - Initial release with Native Assets"

# Verificar tag
git tag -l
git show v0.1.0
```

#### 2.2 Push da tag

```bash
# Push da tag para o GitHub
git push origin v0.1.0
```

### 3. GitHub Actions - Release Automático

Ao fazer push da tag `v0.1.0`, o workflow `.github/workflows/release.yml` será automaticamente acionado:

1. **Build Binaries** (paralelo em 4 plataformas):
   - Ubuntu (Linux x86_64): `libodbc_engine.so`
   - Windows (x86_64): `odbc_engine.dll`
   - macOS Intel (x86_64): `libodbc_engine.dylib`
   - macOS ARM (aarch64): `libodbc_engine.dylib`

2. **Create Release**:
   - Download de todos os artifacts
   - Criação de GitHub Release
   - Upload dos binários para a release
   - Geração automática de release notes

### 4. Verificar Release no GitHub

1. Acessar: https://github.com/cesar-carlos/dart_odbc_fast/releases
2. Verificar se a release `v0.1.0` foi criada
3. Verificar se os 4 binários foram anexados:
   - `x86_64-unknown-linux-gnu/libodbc_engine.so`
   - `x86_64-pc-windows-msvc/odbc_engine.dll`
   - `x86_64-apple-darwin/libodbc_engine.dylib`
   - `aarch64-apple-darwin/libodbc_engine.dylib`

### 5. Publicar no pub.dev

#### 5.1 Autenticação (primeira vez)

```bash
dart pub token add https://pub.dev
```

#### 5.2 Dry-run (validação final)

```bash
dart pub publish --dry-run
```

Verificar:
- Nenhum erro de validação
- Arquivos incluídos estão corretos
- `.pubignore` está funcionando

#### 5.3 Publicar

```bash
dart pub publish
```

Confirmar quando solicitado.

### 6. Pós-Release

#### 6.1 Verificar no pub.dev

Acessar: https://pub.dev/packages/odbc_fast

Verificar:
- Versão publicada
- Documentação gerada
- Pontuação (score)
- Compatibilidade de plataformas

#### 6.2 Anunciar

- [ ] Criar post no changelog do GitHub
- [ ] Compartilhar nas redes (opcional)
- [ ] Atualizar documentação externa (se houver)

## Semantic Versioning

Seguimos [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** (1.0.0): Breaking changes
- **MINOR** (0.1.0): New features (backward compatible)
- **PATCH** (0.1.1): Bug fixes (backward compatible)

### Exemplos

- `0.1.0` → `0.2.0`: Adicionou novas features
- `0.1.0` → `0.1.1`: Corrigiu bugs
- `0.9.0` → `1.0.0`: Primeira versão estável (breaking changes permitidas)
- `1.0.0` → `2.0.0`: Breaking changes

## Troubleshooting

### Tag já existe

```bash
# Deletar tag local
git tag -d v0.1.0

# Deletar tag remota
git push origin :refs/tags/v0.1.0

# Recriar tag
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

### Workflow falhou

1. Verificar logs no GitHub Actions
2. Corrigir problema
3. Deletar tag e recriar (ou usar `workflow_dispatch`)

### Binários não foram anexados

1. Verificar se o workflow `build-binaries` passou
2. Verificar se os artifacts foram criados
3. Verificar se o step `create-release` encontrou os artifacts

## Checklist de Release

Use este checklist para cada release:

- [ ] Versão atualizada no `pubspec.yaml`
- [ ] `CHANGELOG.md` atualizado
- [ ] `dart analyze` sem erros
- [ ] `dart test` passando (100%)
- [ ] CI/CD workflows passando
- [ ] Commit de preparação feito
- [ ] Tag criada e enviada
- [ ] GitHub Release criada automaticamente
- [ ] Binários verificados na release
- [ ] `dart pub publish --dry-run` sem erros
- [ ] Publicado no pub.dev
- [ ] Verificado no pub.dev
- [ ] Anúncio feito (opcional)

## Comandos Rápidos

```bash
# Preparação
dart analyze && dart test
git add . && git commit -m "chore: prepare release v0.1.0"
git push origin main

# Tag e Release
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0

# Publicação
dart pub publish --dry-run
dart pub publish
```
