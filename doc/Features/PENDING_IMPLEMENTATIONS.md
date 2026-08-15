# Implementacoes pendentes

Referencia pratica para o que ainda exige decisao de produto, ambiente live ou
maturacao. O estado abaixo esta alinhado a `pubspec.yaml` `4.5.1`
(sub-interfaces `IQueryService`/`ITransactionService`/`IPoolService`/`IAdminService`/
`IDialectService`,
`IAdminService.events` + `OdbcEvent`, `executeQueryColumnar` /
`streamQueryColumnar`, `TypedColumnarResult`, `QueryResult.columnsMetadata`,
barrels `odbc_fast.dart` / `odbc_fast_native.dart`, sharding completo do
`GlobalState` residual = `env` (+ BCP strings), `OwnedPreparedStatement`,
env var `ODBC_FAST_BLOCK_FETCH_BATCH`).

Esta lista nao repete entregas ja fechadas. Quando uma pendencia virar codigo
ou documentacao canonica, atualizar `CHANGELOG.md`, `doc/CAPABILITIES_v3.md`,
`doc/notes/TYPE_MAPPING.md` e reduzir a secao correspondente aqui.

**Responsabilidade deste arquivo:** backlog de produto/infra e maturacao
operacional. Contratos de tipo/wire vivem em `doc/notes/TYPE_MAPPING.md`;
capabilities entregues vivem em `doc/CAPABILITIES_v3.md`; flags live canonicos
vivem em `doc/TESTING.md`. Indice curto dos itens abertos tambem em
[`notes/ROADMAP_PENDENTES.md`](../notes/ROADMAP_PENDENTES.md) (pointer only).

## 1. Entregue no repo

- **SQL Server MSDTC happy path:** `xa-dtc` no Windows cobre criacao da branch
  MSDTC, `SQL_ATTR_ENLIST_IN_DTC`, `xa_end`/unenlist, `prepare` como estado
  coordenado pelo DTC, `commitPrepared`, `rollback`, `commitOnePhase` e cleanup
  em `Drop`. O que fica aberto e recovery operacional avancado, nao o ciclo
  basico.
- **Oracle XA suportado por produto:** o caminho suportado continua sendo
  `SYS.DBMS_XA` via ODBC/PLSQL. O shim OCI existe como scaffold documentado e
  nao substitui `DBMS_XA`.
- **DRT1 / OUT1 / MULT:** `executeQueryDirectedParams` e o motor nativo suportam
  escalares/texto para `OUT`/`INOUT`, `OUT1` em single-result e `MULT + OUT1`
  quando `SQLMoreResults` produz itens adicionais.
- **Oracle REF CURSOR:** `ParamValueRefCursorOut`, tag 6, trailer `RC1\0`,
  `QueryResult.refCursorResults` e o caminho Oracle `strip ?` +
  `SQLMoreResults` existem. O que falta e certificacao ampla de drivers e
  casos PL/SQL menos comuns.
- **Columnar v2:** o motor emite v2 sob opt-in de `ResultEncoding.columnar` /
  `ResultEncoding.columnarCompressed`, e o Dart decodifica v2 com zstd/LZ4 via
  `odbc_columnar_decompress`.
- **FFI `GlobalState` sharding:** mapas de conexoes/pools/transacoes/streams/
  statements/XA em `ffi::state::*`; residual = `env` (+ BCP strings). Ver
  [`PERFORMANCE.md`](../PERFORMANCE.md).
- **Async XA + recover/resume no service:** isolate protocol cobre `odbc_xa_*`;
  `IOdbcService.xaRecover` / `xaResumePrepared` expostos.
- **`streamQueryNamed` com params:** FFI
  `odbc_stream_start_batched_params*` + fallback buffered em DLLs antigas.
- **`IDialectService`:** builders UPSERT / RETURNING / session-init no aggregate.

### 1.1 Implementado vs certificado em driver live

| Area | Protocolo/codigo | Unit/regression | Certificacao live |
| ---- | ---------------- | --------------- | ----------------- |
| SQL Server MSDTC lifecycle | Implementado em Windows com `xa-dtc`. | `cargo test --lib --features xa-dtc` e `cargo test --no-run --features xa-dtc --tests`. | Manual via `doc/TESTING.md` opt-in flags. |
| SQL Server `OUT` escalar | DRT1 + `OUT1` implementado. | Dart protocolo/repository tests. | Manual via `doc/TESTING.md` opt-in flags. |
| SQL Server `MULT + OUT1` | MULT envelope + `OUT1` implementado. | `d1_drt1_multi_result_wire` e Dart multi-result parser/repository tests. | Manual via `doc/TESTING.md` opt-in flags. |
| PostgreSQL `OUT` escalar | Mesmo DRT1 scalar/text path. | Dart/Rust unit coverage do wire/bind shape. | Manual via `doc/TESTING.md` opt-in flags. |
| Oracle `REF CURSOR` | `ParamValueRefCursorOut` + `RC1\0` implementado. | Rust/Dart protocol and parser coverage. | Manual via `doc/TESTING.md` opt-in flags. |
| Columnar v2 | `ResultEncoding.columnar` / `columnarCompressed` implementados. | Dart/Rust golden and decoder tests. | Manual: DSN real + benchmarks antes de mudar default. |

Matriz canonica de direcoes: [`TYPE_MAPPING.md` secao 3.1.2](../notes/TYPE_MAPPING.md).

## 2. Aberto, mas operacional ou opt-in

### 2.1 SQL Server MSDTC recovery avancado

Nao ha `Reenlist` / resource-manager recovery dentro do crate. O modelo atual
entrega o ciclo feliz e deixa recovery de transacoes in-doubt para MSDTC,
SQL Server e operadores. Se o produto exigir recovery automatizado no processo,
abrir um design separado para:

- contrato de `xa_recover` em SQL Server, considerando que MSDTC usa UoW propria
  e nao o X/Open `Xid` como chave primaria;
- comportamento apos falha de processo, restart do servico MSDTC e falhas entre
  prepare/commit;
- testes live em host Windows com MSDTC rodando.

Runbook local: [`doc/development/msdtc-recovery.md`](../development/msdtc-recovery.md).
Testes opt-in: `xa_dtc_sqlserver_*` com `--features xa-dtc`, `ODBC_TEST_DSN`
e os flags canonicos de live-driver em [`doc/TESTING.md`](../TESTING.md).

CI atual: [`.github/workflows/windows_xa_dtc_build.yml`](../../.github/workflows/windows_xa_dtc_build.yml)
faz compile/clippy/lib tests/no-run no Windows, mas nao inicia MSDTC nem fala
com SQL Server.

### 2.2 Oracle REF CURSOR maturacao

O caminho principal existe. Continuam abertos:

- preencher a tabela de certificacao em `doc/notes/TYPE_MAPPING.md` para drivers
  reais, por exemplo Instant Client ODBC 19/21/23;
- ampliar `native/odbc_engine/tests/e2e_oracle_ref_cursor_test.rs` quando houver
  novos cenarios PL/SQL com row counts intermediarios, cursores vazios ou
  multiplos cursores em ordem incomum;
- manter o teste como opt-in fora do CI Ubuntu padrao, usando os flags
  canonicos de [`doc/TESTING.md`](../TESTING.md).

### 2.3 Columnar v2 default e benchmarks live

Columnar v2 esta disponivel, mas row-major v1 continua default. Antes de mudar
o default para qualquer workload:

- rodar `native/odbc_engine/benches/columnar_v1_v2_encode.rs`;
- comparar queries largas em DSNs reais usando `ResultEncoding.columnar` e
  `ResultEncoding.columnarCompressed`;
- manter o golden `test/fixtures/columnar_v2_int32_zstd.golden` e os hints de
  erro do FFI de descompressao.

Especificacao: [`doc/notes/columnar_protocol_sketch.md`](../notes/columnar_protocol_sketch.md).

### 2.4 E2E host-side

Estes testes existem, mas sao deliberadamente manuais porque dependem de driver
ODBC local, DSN e permissao no banco. A grafia canonica dos flags opt-in vive em
[`doc/TESTING.md`](../TESTING.md); os alvos sao:

- PostgreSQL `OUT`: `test/e2e/postgres_directed_out_test.dart`;
- SQL Server `OUT`: `test/e2e/mssql_directed_out_test.dart`;
- SQL Server `OUT + MULT`: `test/e2e/mssql_directed_out_multi_rset_test.dart`;
- Oracle ref cursor: `native/odbc_engine/tests/e2e_oracle_ref_cursor_test.rs`.

## 3. Deferido por decisao de produto

### 3.1 OCI XA integrado ao fluxo principal

Manter `SYS.DBMS_XA` como unica implementacao Oracle XA suportada em produto.
O modulo `xa_oci` permanece scaffold/deferred ate existir uma forma segura de
compartilhar a mesma sessao fisica OCI usada pela pilha ODBC/`odbc-api`.

Se houver pedido de OCI-only, reabrir design antes de merge: o problema central
e sessao compartilhada, nao apenas carregar `libclntsh`/`oci.dll`.

### 3.2 TVP e matriz completa `SqlDataType` x direcao

TVP e cobertura exaustiva de `SqlDataType` para `OUT`/`INOUT` nao entram sem
design fechado. A especificacao gated vive em
[`doc/notes/TVP_DESIGN_GATE.md`](../notes/TVP_DESIGN_GATE.md).

O estado atual continua:

- escalares/texto DRT1 entregues;
- `Binary` em `OUT`/`INOUT` rejeitado com slug estavel
  `DIRECTED_PARAM|binary_out_inout_not_implemented`;
- `ParamValueRefCursorOut` suportado apenas no caminho Oracle;
- `request.output` estilo `node-mssql` e TVP ainda fora da API publica.

## 4. Criterios para remover itens daqui

Remover ou encurtar uma secao quando:

1. existir rastro claro no `CHANGELOG.md`;
2. o contrato estiver refletido em `doc/CAPABILITIES_v3.md` e
   `doc/notes/TYPE_MAPPING.md`;
3. os exemplos e comandos opt-in estiverem atualizados;
4. o item nao exigir mais decisao externa de produto/infra.

Ultima atualizacao: 2026-06-15.
