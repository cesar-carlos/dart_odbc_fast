# RELEASE_AUTOMATION.md - Processo de release

Este projeto usa o workflow `release.yml` para gerar binarios nativos quando uma tag `v*` e enviada.

## Fluxo oficial

1. Atualizar `pubspec.yaml` (versao) e `CHANGELOG.md`.
2. Rodar validacoes locais.
3. Criar tag `vX.Y.Z` e dar push.
4. Workflow de release compila Linux/Windows e cria GitHub Release com os binarios.
5. Publicar pacote no pub.dev.

## Arquivo de workflow

- `.github/workflows/release.yml`

Trigger:

- `push` em tags `v*`
- `workflow_dispatch`

## O que o workflow faz

### Job `build-binaries`

- Build Linux: `x86_64-unknown-linux-gnu` -> `libodbc_engine.so`
- Build Windows: `x86_64-pc-windows-msvc` -> `odbc_engine.dll`
- Upload dos artefatos por plataforma

### Job `create-release`

- Download dos artefatos
- Publicacao da release via `softprops/action-gh-release`
- Anexos esperados na release:
  - `odbc_engine.dll`
  - `libodbc_engine.so`

## Checklist de release

1. `dart test`
2. `cd native && cargo build --release`
3. `dart pub publish --dry-run`
4. Atualizar `CHANGELOG.md`
5. Commit de release
6. Criar e enviar tag
7. Verificar release no GitHub
8. Publicar no pub.dev

## Comandos

```bash
# commit
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: release X.Y.Z"
git push origin main

# tag
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z

# publicar
dart pub publish
```

## Verificacao pos-release

1. GitHub Release contem os 2 binarios na raiz.
2. Versao publicada no pub.dev corresponde a tag.
3. `dart pub add odbc_fast` + `dart pub get` funciona em ambiente limpo.

## Falhas comuns

### `cp: cannot stat`

Use o caminho de workspace no workflow:

`native/target/${{ matrix.target }}/release/${{ matrix.artifact }}`

### `Pattern 'uploads/*' does not match any files`

Garanta em `download-artifact`:

- `pattern: '*'`
- `merge-multiple: true`

### `403` ao criar release

Verifique permissao no workflow:

```yaml
permissions:
  contents: write
```

## Rollback

Se a tag saiu errada:

```bash
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
```

Depois, publique uma nova versao corrigida.
