# CHANGELOG_TEMPLATE.md - Modelo de changelog

Template recomendado para `CHANGELOG.md`, baseado em Keep a Changelog.

## Estrutura base

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.3.2] - 2026-02-15

### Added

- Example item.

### Fixed

- Example item.

[0.3.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.3.2
```

## Como escrever boas entradas

1. Escreva impacto para o usuario, nao apenas detalhe interno.
2. Use nome do componente afetado em negrito.
3. Para breaking change, inclua migracao curta.
4. Evite texto generico como "varias melhorias".

## Exemplo de breaking change

```markdown
### Breaking Changes

- **IOdbcService.execute**: renomeado para `executeQuery`.
  - Migracao: substitua chamadas para `execute(...)` por `executeQuery(...)`.
```

## Fluxo de atualizacao

1. Durante desenvolvimento, registrar em `[Unreleased]`.
2. No release, criar secao `## [X.Y.Z] - YYYY-MM-DD`.
3. Mover itens de `[Unreleased]` para a nova secao.
4. Atualizar links de comparacao no fim do arquivo.

## Checklist antes de tag

- [ ] `pubspec.yaml` com nova versao
- [ ] `CHANGELOG.md` atualizado
- [ ] breaking changes com migracao
- [ ] links de comparacao atualizados
