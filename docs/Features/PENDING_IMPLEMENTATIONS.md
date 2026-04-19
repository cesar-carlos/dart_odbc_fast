# Implementações pendentes

Lista consolidada do que **ainda não está implementado** ou está **parcialmente implementado**, com referência ao detalhe técnico no repositório.

**Referência de versão:** v3.4.2 (Dart helpers XA) / engine Rust alinhado ao `pubspec.yaml`.

**Documento canônico de backlog técnico:** [`doc/notes/FUTURE_IMPLEMENTATIONS.md`](../../doc/notes/FUTURE_IMPLEMENTATIONS.md) — mantém histórico, critérios de “done” e notas longas. Este ficheiro resume o que falta para leitura rápida.

---

## 1. Transações distribuídas (XA / 2PC)

### 1.1 SQL Server — MSDTC (Sprint 4.3b, Phase 2)

**Estado:** Phase 1 concluída (módulo `engine::xa_dtc`, feature `--features xa-dtc`, Windows). A matriz `apply_xa_*` em `xa_transaction.rs` continua a devolver `UnsupportedFeature` para SQL Server.

**Pendente:**

- Integrar `engine::xa_dtc::begin_dtc_branch()` na matriz `apply_xa_*`.
- Enlistar a ligação ODBC via `SQLSetConnectAttr(SQL_ATTR_ENLIST_IN_DTC, ITransaction*)` (escape hatch em cima do handle raw; `odbc-api` não expõe o atributo).
- Recuperação após falha: `IResourceManager::Reenlist` (crash recovery MSDTC).
- Testes E2E ignorados / gated, por exemplo `tests/regression/xa_dtc_test.rs`, com `cargo test --features xa-dtc -- --ignored --test-threads=1` num host Windows com MSDTC a correr (`sc query MSDTC`).

**Prioridade:** baixa (infraestrutura Windows + MSDTC).

---

### 1.2 Oracle — caminho OCI XA (alternativo ao `DBMS_XA`)

**Estado:** XA em Oracle está **implementado em produção** via `SYS.DBMS_XA` (v3.4.1). O módulo `engine::xa_oci` (feature `--features xa-oci`) mantém o *shim* de carregamento dinâmico dos símbolos `xa_*` da OCI.

**Pendente (opcional / futuro):**

- Ligar o *shim* OCI à matriz `apply_xa_*` só faria sentido se existir forma estável de partilhar a sessão OCI com a ligação ODBC (hoje `odbc-api` não expõe `OCIServer*`).
- Validação E2E contra instância com `XA_OPEN` registado, se algum dia o caminho OCI for escolhido em vez de `DBMS_XA`.

**Prioridade:** baixa (o caminho PL/SQL cobre o caso de uso típico).

---

### 1.3 `IOdbcService.runInXaTransaction` (camada Service)

**Estado:** Existem `XaTransactionHandle.runWithStart` / `runWithStartOnePhase` (v3.4.2) e `IOdbcService.runInTransaction` para transações **locais** (v3.4.0).

**Pendente (melhoria de produto):**

- Expor um helper ao nível do `OdbcService` / `IOdbcService` que orquestre XA com o mesmo estilo de `Result<T>` e telemetria que `runInTransaction`, se quiserem paridade de API *service-first* sem depender só de `NativeOdbcConnection`.

**Prioridade:** baixa (ergonomia; o fluxo já é possível via infraestrutura).

---

## 2. Tipos e protocolo

### 2.1 `SqlDataType` — últimos tipos do roadmap (3 slots)

**Estado:** 27/30 tipos documentados no roadmap; os 3 restantes estão reservados.

**Pendente:** tipos adicionais quando houver consumidor concreto (ex.: geometria espacial, intervalos ano/mês, JSON com validação de schema).

**Prioridade:** baixa.

---

### 2.2 Protocolo columnar v2

**Estado:** *Sketch* em [`doc/notes/columnar_protocol_sketch.md`](../../doc/notes/columnar_protocol_sketch.md); implementação em código foi adiada.

**Pendente:** desenho + implementação FFI/Dart se o projeto avançar para protocolo columnar v2.

**Prioridade:** baixa.

---

## 3. Parâmetros de saída (OUTPUT / REF CURSOR)

**Estado:** documentado em `doc/notes/TYPE_MAPPING.md` (secção de roadmap); **fora do escopo imediato**.

**Pendente:** API pública estável + matriz por motor/plugin (ex.: SQL Server `OUTPUT`, Oracle `REF CURSOR`).

**Prioridade:** média quando existir requisito de produto explícito.

---

## 4. Infraestrutura de testes e CI

### 4.1 `e2e_pool_test` / `e2e_savepoint_test` “pendurados” em DSN lento

**Estado:** conhecido; gating com `ENABLE_E2E_TESTS=1`.

**Pendente:** reduzir `connection_timeout` do pool nos testes (ex.: 5 s) e falhar rápido com mensagem clara (ver *fix sketch* em `FUTURE_IMPLEMENTATIONS.md` §3.2).

**Prioridade:** baixa.

---

### 4.2 Db2 no *test-runner* Docker + matriz CI

**Estado:** XA Db2 está implementado no Rust (mesma gramática SQL XA que MySQL). O `Dockerfile.test-runner` **não** instala o pacote IBM CLI/Db2 ODBC (comentário no Dockerfile: tarball/licença).

**Pendente:** integrar driver Db2 no contentor de testes (ex.: pacote IBM ou fluxo de download aceitável em CI) e adicionar entrada `db2` ao workflow `e2e_docker_stack` (ou equivalente) com DSN e testes XA.

**Prioridade:** média (fecha lacuna E2E para Db2 em ambiente reproduzível).

---

### 4.3 Testes de integração Dart / SQL Server no ambiente local

**Estado:** falhas comuns quando `sa`/password ou driver local não coincidem com o esperado pelo teste (ex.: `pool_integration_test`).

**Pendente:** documentar variáveis de ambiente / DSN esperados ou tornar testes mais resilientes a “sem SQL Server”.

**Prioridade:** baixa (ambiente de desenvolvimento, não bug de produto por si).

---

## 5. Resumo por prioridade

| Prioridade | Itens |
| ---------- | ----- |
| **Média**  | Parâmetros de saída (quando houver escopo); Db2 no Docker CI |
| **Baixa**  | MSDTC Phase 2; OCI XA wiring opcional; 3 tipos `SqlDataType`; columnar v2; timeout pool E2E; `runInXaTransaction` no Service; endurecimento testes integração SQL Server |

---

## 6. Critérios para retirar um item desta lista

Alinhado ao backlog canónico:

1. API pública definida e documentada (quando aplicável).
2. Testes unitários e de integração cobrindo o fluxo principal.
3. Exemplo em `example/` quando fizer sentido para o utilizador.
4. Entrada em `CHANGELOG.md`.

Quando um item cumprir estes critérios, deve ser marcado como implementado em `doc/notes/FUTURE_IMPLEMENTATIONS.md` e **removido ou arquivado** neste ficheiro para evitar duplicação.

---

*Última atualização do conteúdo: alinhado a `doc/notes/FUTURE_IMPLEMENTATIONS.md` e ao estado do repositório na data da criação deste documento.*
