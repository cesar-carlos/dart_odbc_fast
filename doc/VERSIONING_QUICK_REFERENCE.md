# VERSIONING_QUICK_REFERENCE.md - Referencia rapida

## Decisao em 10 segundos

Se esta em `0.x.y`:

- Breaking de API publica -> `0.(x+1).0`
- Nao-breaking (feature/fix/docs/perf) -> `0.x.(y+1)`

Se esta em `>=1.0.0`:

- Breaking -> `MAJOR`
- Feature compativel -> `MINOR`
- Fix/perf/docs -> `PATCH`

## Tabela rapida (pre-1.0.0)

| Tipo de mudanca | Bump |
| --- | --- |
| Renomear/remover API publica | MINOR |
| Alterar retorno publico | MINOR |
| Adicionar parametro obrigatorio | MINOR |
| Adicionar metodo novo | PATCH |
| Adicionar parametro opcional | PATCH |
| Bug fix | PATCH |
| Performance | PATCH |
| Documentacao | PATCH |

## Checklist de breaking

Marque como breaking se qualquer item for verdadeiro:

- [ ] Remove API publica
- [ ] Renomeia API publica
- [ ] Altera assinatura/retorno de API publica
- [ ] Remove compatibilidade sem periodo de migracao

## Exemplos

1. `execute(String sql)` -> `execute(String sql, {Duration? timeout})`
Resultado: PATCH.

2. `execute(String sql)` -> `executeQuery(String sql)`
Resultado: MINOR (pre-1.0.0) / MAJOR (pos-1.0.0).

## Comandos uteis

```bash
# ver versao atual
rg "^version:" pubspec.yaml

# criar tag estavel
git tag -a v0.3.2 -m "Release v0.3.2"
git push origin v0.3.2
```

## Referencias

- [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)
