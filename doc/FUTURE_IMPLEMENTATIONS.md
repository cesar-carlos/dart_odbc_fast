# FUTURE_IMPLEMENTATIONS.md - Backlog tecnico

Backlog consolidado de itens que ainda nao fazem parte do escopo implementado.

## Resumo

| Item | Status | Prioridade |
| --- | --- | --- |
| Schema reflection (PK/FK/Indexes) | Aberto | Alta |
| Bulk insert paralelo via FFI | Aberto | Media |
| Output parameters por driver/plugin | Fora de escopo atual | Media |

## 1. Schema reflection (PK/FK/Indexes)

### Estado atual

- Existe suporte de catalogo basico (tabelas/colunas/tipos).
- Entidades de dominio para PK/FK/Indexes ja existem.

### Falta implementar

1. Funcoes Rust para listar PK/FK/Indexes.
2. Exposicao FFI correspondente.
3. Metodos no repositorio/servico Dart.
4. Testes de integracao com banco real.

## 2. Bulk insert paralelo via FFI

### Estado atual

- O engine Rust possui base para parallel insert.
- O caminho exposto para Dart usa bulk insert tradicional por conexao.

### Falta implementar

1. Surface FFI estavel para caminho paralelo.
2. API Dart para selecionar estrategia paralela.
3. Validacao de throughput (benchmarks e stress).

## 3. Output parameters por driver/plugin

### Estado atual

- Nao existe API publica para output parameters.
- Existem pontos de extensao no engine/plugins, mas sem contrato estavel para Dart.

### Decisao atual

- Fora do escopo imediato.
- Retornar ao tema quando houver requisito de driver especifico (ex.: SQL Server OUTPUT, Oracle REF CURSOR).

## Criterios para mover item de aberto para implementado

1. API publica definida e documentada.
2. Testes unitarios e de integracao cobrindo fluxo principal.
3. Exemplo funcional em `example/` (quando aplicavel).
4. Entrada no `CHANGELOG.md`.
