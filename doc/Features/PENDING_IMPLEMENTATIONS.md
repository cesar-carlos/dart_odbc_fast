# Implementações pendentes

Lista **mínima** do que continua fora de escopo de produto *neste momento*,
após o plano *Backlog fechado v3.x* (Fases 0–7 + documentação canónica). O que
já foi entregue regista-se no `CHANGELOG.md` e, quando aplicável, em
`doc/CAPABILITIES_v3.md` e `doc/notes/TYPE_MAPPING.md`.

**Referência de versão:** alinhada ao `pubspec.yaml` e ao `CHANGELOG.md`
secção `[Unreleased]`.

**Ordem sugerida de *epics* (não substitui esta lista):**
[`doc/notes/ROADMAP_PENDENTES.md`](../notes/ROADMAP_PENDENTES.md).

---

## 1. Onde ainda há trabalho (nativo / produto)

### 1.1 SQL Server — MSDTC (recuperação avançada)

A integração DTC (enlist, ciclo, prepare/commit) está implementada atrás de
`--features xa-dtc` (Windows). *Reenlist* / *resource-manager* recovery
**não** vivem dentro do *crate* — ver o aviso de *scope* e a coluna
“o que a *app* pode fazer / mensagem” em
[`doc/development/msdtc-recovery.md`](../development/msdtc-recovery.md).
**Fechado em documentação (eng):** mapeamento de expectativas e erros; não há
*Reenlist* no processo. **Pendente (operacional, fora do repo se não houver
prioridade),** se o produto exigir: testes *runtime* reais, *tuning* com
falhas *exóticas*, runners Windows em CI pago. **Runbook (anfitrião Windows):** secção
*Local runbook* em
[`msdtc-recovery.md`](../development/msdtc-recovery.md) — dois testes
`#[ignore]` no *binário* `regression_test` (*rollback* após *prepare* e
*commit* após *prepare*; *filter* `xa_dtc_sqlserver_`, ver tabela;
`--ignored`, `ENABLE_E2E_TESTS=1`, DSN). **CI opcional (manual, sem E2E DTC):**
[`.github/workflows/windows_xa_dtc_build.yml`](../../.github/workflows/windows_xa_dtc_build.yml) —
*clippy*, *build* `xa-dtc`, `cargo test --lib`, e compilação de *integration
tests* (`--no-run`); **não** inicia o serviço MSDTC nem fala com SQL Server.
**Não** existe no repositório um *job* agendado que execute os dois testes
`xa_dtc_sqlserver_*` com DSN *live* (isso seria **CI Windows pago** ou *runner*
*ad hoc* se o produto o financiar — fora do *default* *open source*).

### 1.2 Oracle — caminho OCI XA (paridade com `DBMS_XA`)

**Decisão de produto:** manter o caminho `SYS.DBMS_XA` como *única*
implementação suportada. O *shim* `xa-oci` permanece *deferido* até existir
API estável de partilha de sessão OCI com a pilha `odbc-api` / ODBC (detalhes
no módulo `xa_oci` e comentários em `native/odbc_engine/src/engine/xa_oci.rs`).
**Checklist por *release* (governação):** confirmar que a política *DBMS_XA*
*vs.* *shim* não mudou; se houver pedido de código OCI partilhado, reabrir
discussão antes de *merge*.

Rever em cada *release* se a política se mantém (roadmap:
[`ROADMAP_PENDENTES.md`](../notes/ROADMAP_PENDENTES.md) ordem 3).

### 1.3 Parâmetros de saída — extensão além do MVP

DRT1, `OUT1`, `executeQueryDirectedParams`, escalares e **teor textual**
estão em `doc/notes/TYPE_MAPPING.md` §3.1; pré-validação *slug* alinhada no
*client* Dart (`validateDirectedOutInOut`). **Já entregue:** o *path* DRT1
suporta o caso clássico *single-result* (`ODBC` + `OUT1`) e, quando
`SQLMoreResults` produz itens adicionais, o motor emite `MULT` + `OUT1`; no
Dart, o primeiro *result set* continua em `QueryResult.columns` / `rows` /
`rowCount` e a cauda vai para `QueryResult.additionalResults`. **REF CURSOR
(Oracle):** *wire* tag 6, *trailer* `RC1\0` e `QueryResult.refCursorResults` no
Dart; *motor* com plugin Oracle: *strip* de `?` + `SQLMoreResults` (ver
`ref_cursor_oracle`, §3.1.1, nota
[`REF_CURSOR_ORACLE_ROADMAP`](../notes/REF_CURSOR_ORACLE_ROADMAP.md)). **Ainda
em aberto (produto / maturação):** certificação *driver* a *driver* além da
matriz, *edge* de PL/SQL, e tabela `SqlDataType`×direcção completa além de
`ParamValue` sob carga.

### 1.4 Columnar v2 (compressão e paridade de *bench*)

O motor emite v2; o Dart decodifica v2. **Compressão por coluna:** o parser
chama o FFI `odbc_columnar_decompress` (zstd=1, lz4=2) do mesmo *crate*.
*Benchmark* Criterion v1 vs v2 (com e sem *zstd*):
`native/odbc_engine/benches/columnar_v1_v2_encode.rs` — comandos em
[`columnar_protocol_sketch.md`](../notes/columnar_protocol_sketch.md) (*Criterion
benches*). *Golden* `test/fixtures/columnar_v2_int32_zstd.golden`. O *client*
Dart inclui **mensagens** *hint* na `FormatException` quando a descompressão
nativa falha (*DLL* em falta, *payload* inválido). Especificação:
[`doc/notes/columnar_protocol_sketch.md`](../notes/columnar_protocol_sketch.md).

---

## 2. Infra e DX (opcional)

**TVP** (SQL Server *table-valued parameters*) e matriz completa
`SqlDataType`×direcção **não** estão no *roadmap* curto salvo prioridade de
produto — ver *Non-goals* em `TYPE_MAPPING` e ordem 4 em
[`ROADMAP_PENDENTES.md`](../notes/ROADMAP_PENDENTES.md).

Fora de *escopo* OCI adicional (além de §1.2) — a lista mantém o *guidance*,
incluindo *fixtures* de *protocol* e testes *opt-in* (ver
`doc/development/docker-test-stack.md`).

- **E2E Windows MSDTC** — dois testes *integration* *opt-in* `xa_dtc_sqlserver_*`
  (passo `-- --ignored` ao `cargo test`); requerem anfitrião Windows real,
  MSDTC a correr e DSN; ver *Local runbook* em `msdtc-recovery.md`. Não correm
  no CI *ubuntu* predefinido.
- **E2E lento** — o *pool* E2E usa *timeout* curto (5s) no código para falhar
  rápido; ver `doc/development/docker-test-stack.md` (secção
  *E2E env, slow DSN*). `e2e_savepoint_test` e semelhantes usam
  `ENABLE_E2E_TESTS=1` quando apropriado.
- **E2E PostgreSQL `OUT`** — teste Dart *opt-in* com `E2E_PG_DIRECTED_OUT=1` e
  `ODBC_TEST_DSN` (procedimento `public.odbc_e2e_directed_out`, `CALL` DRT1);
  corre no **anfitrião** (Dart + ODBC), não no `test-runner` do stack Docker; não
  faz parte do CI *ubuntu* predefinido.
- **E2E SQL Server `OUT` + multi-result** — teste Dart *opt-in* com
  `E2E_MSSQL_DIRECTED_OUT_MULTI=1` e `ODBC_TEST_DSN`
  (`test/e2e/mssql_directed_out_multi_rset_test.dart`); valida o caminho
  `MULT` + `OUT1` com dois `SELECT` e `OUTPUT`. Corre no **anfitrião**
  (Dart + ODBC), não no `test-runner` do stack Docker; não faz parte do
  CI *ubuntu* predefinido.

---

## 3. Critérios para voltar a listar itens aqui

1. Não houver ainda rasto claro no `CHANGELOG.md`.
2. Haja impacto de produto (API, semântica, ou CI bloqueada).

*Última actualização: 2026-04-24: DRT1 + `OUT1` + `MULT` alinhados com
`TYPE_MAPPING` / `CHANGELOG`; `QueryResult.additionalResults` e
`QueryResult.refCursorResults` reflectidos; PENDING §1.1 (*CI* DTC *live*
explícito como *ad hoc*); §1.2 *checklist* *release* OCI XA; §1.4 *DX*
descompressão; §2 *scope* TVP / `SqlDataType`.*
