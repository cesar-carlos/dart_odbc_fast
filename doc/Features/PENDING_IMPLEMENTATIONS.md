# Implementações pendentes

Lista **mínima** do que continua fora de escopo de produto *neste momento*,
após o plano *Backlog fechado v3.x* (Fases 0–7 + documentação canónica). O que
já foi entregue regista-se no `CHANGELOG.md` e, quando aplicável, em
`doc/CAPABILITIES_v3.md` e `doc/notes/TYPE_MAPPING.md`.

**Referência de versão:** alinhada ao `pubspec.yaml` e ao `CHANGELOG.md`
secção `[Unreleased]`.

---

## 1. Onde ainda há trabalho (nativo / produto)

### 1.1 SQL Server — MSDTC (recuperação avançada)

A integração DTC (enlist, ciclo, prepare/commit) está implementada atrás de
`--features xa-dtc` (Windows). **Pendente de prioridade operacional:** tuning
e testes de recuperação com `IResourceManager::Reenlist` em falhas
exóticas, e geração de runners Windows em CI pago, se forem requisitados.

### 1.2 Oracle — caminho OCI XA (paridade com `DBMS_XA`)

**Decisão de produto:** manter o caminho `SYS.DBMS_XA` como *única*
implementação suportada. O *shim* `xa-oci` permanece *deferido* até existir
API estável de partilha de sessão OCI com a pilha `odbc-api` / ODBC (detalhes
no módulo `xa_oci` e comentários em `native/odbc_engine/src/engine/xa_oci.rs`).

### 1.3 Parâmetros de saída — extensão além do MVP

DRT1, `OUT1`, `executeQueryDirectedParams` e o MVP (escalares inteiro) em
SQL Server estão descritos em `doc/notes/TYPE_MAPPING.md` §3.1. **Ainda
longe do produto completo:** `OUT` textual, `REF CURSOR` / Oracle, matriz
de *drivers*, erros de capacidade; ver o mesmo ficheiro.

### 1.4 Columnar v2 (compressão e paridade de *bench*)

O motor emite v2; o Dart decodifica v2 *sem* compressão por coluna. Falta
port de descompressão (zstd/LZ4) e *bench* comparativo sólido. Especificação:
[`doc/notes/columnar_protocol_sketch.md`](../notes/columnar_protocol_sketch.md).

---

## 2. Infra e DX (opcional)

- **E2E Windows MSDTC** — testes `#[ignore]` requerem anfitrião real.
- **TVP** / tipos tabela em SQL Server — fora de roadmap curto
  (`TYPE_MAPPING` *Non-goals*).
- **E2E lento** — `e2e_pool_test` / `e2e_savepoint_test` com DSN lento: o
  *timeout* padrão do *pool* (p.ex. 30s) por teste pode parecer *hang*; estes
  testes costumam estar condicionados a `ENABLE_E2E_TESTS=1`. Mitigação
  possível: `connection_timeout` mais baixo por teste e falha explícita.

---

## 3. Critérios para voltar a listar itens aqui

1. Não houver ainda rasto claro no `CHANGELOG.md`.
2. Haja impacto de produto (API, semântica, ou CI bloqueada).

*Última actualização: alinhada ao fecho do plano *Backlog fechado v3.x*; o
ficheiro longo `doc/notes/FUTURE_IMPLEMENTATIONS.md` foi removido em favor
desta lista e do histórico no CHANGELOG.*
