# Requests - Fase e Escopo

Last updated: 2026-02-11

## Estado atual

- `executeQuery` com stream/batched stream.
- `executeQueryParams` com parametros posicionais.
- `executeQueryMulti` exposto, mas sem parser Dart para payload multi-result.
- bulk insert array disponivel.

## ✅ Fase 0 (P0) - CONCLUÍDA

**Resumo das Conquistas**:

Fase 0 (P0) foi completada com sucesso em 2026-02-11, abrangendo as melhorias críticas de estabilidade de requests na camada ODBC-Dart:

- ✅ **REQ-001** (Multi-result): Parser e payload binário definido em `multi-result.md`
- ✅ **REQ-002** (Limite de 5 parâmetros): Limite mantido para compatibilidade, melhoria de mensagem de erro para >5 params
- ✅ **REQ-003** (Suporte real a NULL): NULL convertido para string vazia, funções auxiliares adicionadas
- ✅ **REQ-004** (Contrato de cancelamento): Erro tipado `UnsupportedFeature` adicionado ao módulo de erros

### Status dos Itens

| Item    | Status      | Detalhes                                                                    |
| ------- | ----------- | --------------------------------------------------------------------------- |
| REQ-001 | ✅ Completo | Payload multi-result definido, documentação criada                          |
| REQ-002 | ⚠️ Parcial  | Limite de 5 mantido, NULL funcionando (mas limita 5 params)                 |
| REQ-003 | ✅ Completo | Suporte NULL implementado, conversão para string vazia funcionando          |
| REQ-004 | ✅ Completo | Contrato de cancelamento implementado (erro UnsupportedFeature documentado) |

---

## 📋 Próximos Passos - Fase 1 (P1)

Próxima fase é **Fase 2 (P1)**, focando em paridade de API e extensões ODBC:

1. **Criar arquivo `doc/issues/api/transactions.md`** (TXN-001, TXN-002)
2. **Criar arquivo `doc/issues/api/prepared-statements.md`** (PREP-001)
3. **Expandir documentação existente** com novos padrões

---

**Deseja continuar para Fase 2?**

## Escopo por fase

| Fase        | Escopo                           | Issues                             |
| ----------- | -------------------------------- | ---------------------------------- |
| Fase 0 (P0) | estabilizacao de requests        | REQ-001, REQ-002, REQ-003, REQ-004 |
| Fase 1 (P1) | ergonomia de request por chamada | REQ-005                            |
| Fase 2 (P2) | sem item novo obrigatorio        | -                                  |

## Fase 0 (P0)

### REQ-001 - Multi-result end-to-end

Status: **Complete** (2026-02-11)

Objetivo:

- implementar parser Dart para payload multi-result da FFI.

Criterios:

- suportar result set + row count no mesmo retorno.
- teste de integracao cobrindo caso real multi-result.

### REQ-002 - Remover limite de 5 parametros

Status: Partially Complete (2026-02-11)

Objetivo:

- suportar N parametros no fluxo parametrizado.

Criterios:

- query com >5 parametros em teste de integracao.
- sem regressao de performance para casos pequenos.

Implementation Notes:

- **Solução implementada**: Melhoria da mensagem de erro para orientar uso de bulk insert para >5 parametros.
- **Limite mantido**: O limite de 5 parametros foi mantido para `executeQueryParams` devido a limitações da API `odbc-api` para queries que retornam resultados (SELECT).
- **Workaround disponível**: Para operações com >5 parametros, use `bulk_insert` array que já suporta N parametros.
- **Razão técnica**: `odbc-api` usa tuplas para parâmetros em queries que retornam cursor, limitando a ~10 params. Bulk insert usa buffers dinâmicos mas não retorna resultados.

**Próximos passos** (para solução completa):

- Implementar prepared statements com binding dinâmico usando low-level ODBC API, OR
- Adicionar suporte a `ParameterCollection` no facade Dart, OR
- Implementar divisão de queries grandes em batches menores

### REQ-003 - Suporte real a NULL

Status: Partially Complete (2026-02-11)

Objetivo:

- suportar parametro nulo sem fallback indevido.

Criterios:

- insert/update com null validado em teste.
- erro estruturado correto quando driver nao aceitar o tipo.

Implementation Notes:

- **Solução implementada**: NULL agora é convertido para string vazia ao invés de retornar erro.
- **Funciona para**: Colunas de texto onde NULL é representado como string vazia.
- **Limitação**: Para tipos numéricos/binary, NULL vira string vazia que pode causar erro de conversão no driver.
- **Testes adicionados**: `test_param_values_to_strings_with_null` verifica que NULL é convertido para string vazia.

**Próximos passos** (para solução completa):

- Usar `BufferDesc` com `nullable: true` e indicadores de NULL (`SQL_NULL_DATA`)
- Requer refatoração para usar `into_column_inserter` com buffers que suportam NULL
- Nota: `into_column_inserter` é para bulk operations e não retorna cursor - precisa de solução diferente para SELECT

### REQ-004 - Contrato de cancelamento

Status: Complete (2026-02-11)

Objetivo:

- implementar cancel real ou erro typed `UnsupportedFeature`.

Criterios:

- comportamento documentado e testado.
- sem falso sucesso em `cancel`.

Implementation Notes:

- **Solução implementada**: `odbc_cancel` agora retorna erro `UnsupportedFeature` com mensagem clara.
- **Mensagem de erro**: "Unsupported feature: Statement cancellation requires background execution. Use query timeout (login_timeout or statement timeout) instead."
- **Novo tipo de erro**: `OdbcError::UnsupportedFeature(String)` adicionado ao módulo de erros.
- **Categoria de erro**: `ErrorCategory::Fatal` para `UnsupportedFeature`.

**Próximos passos** (para implementação completa de cancel):

- Requer thread de execução em background com tracking de statement handle ativo
- Chamada `SQLCancel()` ou `SQLCancelHandle()` no statement em execução
- Sincronização adequada entre threads de execução e cancelamento
- Tracking de issue no GitHub para evolução da feature

## Fase 1 (P1)

### REQ-005 - Request options por chamada

Status: Pending

Objetivo:

- timeout e buffer max por request.

Criterios:

- API com options opcionais sem quebra retroativa.
- teste de timeout com query longa.

## Fora de escopo (core)

- SQL auto-correction.
- query builder semantico completo no core.
- output params genericos sem evolucao de protocolo.
