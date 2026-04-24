# Oracle `SYS_REFCURSOR` OUT — *spike* e plano de implementação

**Estado (motor, Oracle + plugin activo):** `ParamValue::RefCursorOut` no buffer DRT1
activa o *path* `engine::core::ref_cursor_oracle` + `execute_oracle_ref_cursor_path` em
[`execution_engine.rs`](../../native/odbc_engine/src/engine/core/execution_engine.rs):
os `?` para *ref cursor* são **retirados** do texto SQL (modelo *Oracle Database ODBC —
Enabling Result Sets*), os restantes *binds* vão para `OutputAwareParams`, e o motor usa
`prepare` + `execute` + o primeiro *cursor* + `SQLMoreResults` para recolher *um result
set* por *ref cursor* na ordem do procedimento, codificando cada um em v1 (obrigatório
para o trailer `RC1\0`).

O *wire* no cliente (tag 6, `OUT1` só escalares, `RC1\0`, `QueryResult.refCursorResults`) está
em [TYPE_MAPPING.md](TYPE_MAPPING.md) §3.1.1.

**Estado (não-Oracle):** o uso de `ParamValue::RefCursorOut` continua a falhar cedo com
`DIRECTED_PARAM|ref_cursor_out_oracle_only:…` (não suportar *bind* *REF CURSOR* fora
do *stack* documentado). Chamadas a `bound_to_slots` *sem* o filtro do *path* Oracle
(Defesa) ainda recebem
`DIRECTED_PARAM|ref_cursor_out_bind_not_enabled:…` em
`output_aware_params::bound_to_slots`.

**Spike (Validação fora de motor):** com *DSN* Oracle, *procedure* mínima com
`IN OUT` / `OUT SYS_REFCURSOR`, call `{CALL ...}` com só os *bind* escalares, e
`SQLMoreResults` (como o exemplo C em *Oracle Database ODBC for Programmers*). Não
é necessário `SQLBindParameter` para o tipo *REF CURSOR* nesse *driver*; o padrão
*omit* + *result sets* aplica-se.

## 1. Ponto de integração: `execute_query_with_bound_params_and_timeout`

Ficheiro: [`execution_engine.rs`](../../native/odbc_engine/src/engine/core/execution_engine.rs)

Fluxo (Oracle, resumo):

1. `bound_has_ref_cursor` → *strip* `?` (ver
   [`ref_cursor_oracle.rs`](../../native/odbc_engine/src/engine/core/ref_cursor_oracle.rs)),
   `filter_non_ref_cursor_params`, `bound_to_slots(&filtered)`.
2. `conn.prepare` + `set_query_timeout_sec` (opcional) + `execute`.
3. Primeiro *cursor* (se existir) → `encode_cursor_v1` → *blob* `RC1\0` (v1 puro; o
   *main* lógico fica *empty* `RowBuffer` + columnar/v1 conforme a configuração do
   *engine*).
4. `drive_more_ref_cursor_blobs` — só *result sets* com colunas; *row counts*
   intermédios consomem `more_results` sem acrescentar a `RC1`.
5. Verificar o número de *blobs* = número de `RefCursorOut` em `bound`.
6. `output_footer_values` (só *slots* escalar / texto; nunca *ref cursor*).
7. `append_output_footer` → `append_ref_cursor_footer`.

**Contrato com o Dart / `OUT1`:** a lista de escalares do `OUT1` contém **apenas**
parametrização `OUT` / `INOUT` que não sejam `ParamValue::RefCursorOut` — na mesma
ordem de `?` *rest* no SQL.

## 2. Tarefas em aberto (pós-PR)

- Certificação *driver* a *driver* (Instant Client, versões) e procedimentos só
  *OUT* (sem *IN* escalar) ou muitas colunas.
- *Stress* e matriz *SqlDataType*×direcção além de `ParamValue` (se produto
  exigir).
- *Erro* mais rico se `ref_cursor_oracle_resultset_count` (contagem *result
  sets* ≠ número de *markers*).
- *Edge* / *backlog* (validar *real* e acrescentar *tests* *ignore* se *regressar*):
  *procedures* que emitem *row counts* / *no-data* *result sets* entre *ref
  cursors*; *packages* com *overload*; muitas colunas no *ref cursor*; e consumo
  *correcto* de *MoreResults* quando o *driver* devolve *intermediate* *done*
  *procedures*.

## 3. E2E

- *Integration* *opt-in* *ignored*:
  `native/odbc_engine/tests/e2e_oracle_ref_cursor_test.rs` — `E2E_ORACLE_REFCURSOR=1`
  e *DSN*.

## 4. Pós-fases (roadmap geral)

- **MSDTC (PENDING):** fora do *ref cursor*.
- **OCI XA *shim*:** *defer*; [ROADMAP_PENDENTES](ROADMAP_PENDENTES.md).
- **Columnar (§1.3–1.4):** *ref cursor* *blobs* permanecem v1; *main* pode ser v2
  *columnar* se activo no *engine*.

**Critério (histórico):** o *slug* `ref_cursor_out_bind_not_enabled` deixa de ser o
*happy path* na combinação Oracle+plugin+strip; ainda aplica-se a *direct*
`bound_to_slots` com `RefCursorOut` (defesa) ou a motores que não forem o documentado.
