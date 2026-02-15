# VERSIONING_STRATEGY.md - Estrategia de versionamento

## Objetivo

Definir uma politica unica para versao do pacote, tags e comunicacao de breaking changes.

## Estado atual

- Versao atual do pacote: `0.3.1`
- Fase: pre-1.0.0 (API ainda evoluindo)

## Regra principal (pre-1.0.0)

Para `0.x.y`:

- Breaking change de API publica: incrementa **MINOR** (`0.3.1` -> `0.4.0`)
- Nova feature compativel: incrementa **PATCH** (`0.3.1` -> `0.3.2`)
- Bug fix/performance/docs: incrementa **PATCH**

## Regra apos 1.0.0

Para `x.y.z`:

- Breaking change: **MAJOR**
- Nova feature compativel: **MINOR**
- Bug fix/performance/docs: **PATCH**

## O que conta como breaking

1. Remover metodo/classe/enum publica.
2. Renomear API publica.
3. Alterar tipo de retorno publico.
4. Adicionar parametro obrigatorio.
5. Remover parametro existente.
6. Mudar comportamento contratual sem fallback.

## O que nao e breaking

1. Adicionar metodo novo.
2. Adicionar parametro opcional com valor padrao.
3. Melhoria interna sem alterar assinatura/contrato.
4. Melhorias de erro, logs e performance sem mudanca funcional externa.

## Politica de deprecation

1. Primeiro release: marcar como `@Deprecated` e documentar alternativa.
2. Manter por pelo menos 2 releases pre-1.0.0 (ou 2 MINOR apos 1.0.0).
3. Remover apenas em release de breaking change.

## Tags

Formato:

- Estavel: `vX.Y.Z`
- Release candidate: `vX.Y.Z-rc.N`
- Beta: `vX.Y.Z-beta.N`
- Dev: `vX.Y.Z-dev.N`

## Checklist de bump

1. Definir tipo de mudanca (breaking ou nao).
2. Atualizar `pubspec.yaml`.
3. Atualizar `CHANGELOG.md` com secoes corretas.
4. Validar testes/build.
5. Criar tag.

## Exemplo de decisao

### Exemplo A - parametro opcional novo

Mudanca:

```dart
Future<QueryResult> execute(String sql, {Duration? timeout});
```

Decisao em `0.3.1`: `0.3.2` (PATCH).

### Exemplo B - renomear metodo publico

Mudanca:

- `execute` -> `executeQuery`

Decisao em `0.3.2`: `0.4.0` (MINOR).

## Documentos relacionados

- [VERSIONING_QUICK_REFERENCE.md](VERSIONING_QUICK_REFERENCE.md)
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)
- [CHANGELOG.md](../CHANGELOG.md)
