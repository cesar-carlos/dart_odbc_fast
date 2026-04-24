# Roadmap: itens ainda abertos (ordenado)

Lista operacional derivada de
[`PENDING_IMPLEMENTATIONS`](../Features/PENDING_IMPLEMENTATIONS.md) e da
necessidade de **ordenar** trabalho (não tudo tem o mesmo tamanho ou a mesma
dependência de ambiente). Para detalhe sobre um *epic* específico, ver a nota
dedicada.

| Ordem | Tema | Nota de implementação | Estado |
| ----- | ---- | -------------------- | ------ |
| 1 | Oracle `SYS_REFCURSOR` (motor) | [REF_CURSOR_ORACLE_ROADMAP](REF_CURSOR_ORACLE_ROADMAP.md) | *Strip* de `?` + `more_results` + `RC1\0` no motor; maturação *driver* (PENDING) |
| 2 | MSDTC / `xa-dtc` | *Runbook* + workflow manual; *Reenlist* fora do *crate*; operação / CI pago *ad hoc* | *DX* in-tree em grande parte fechada; ver PENDING §1.1 |
| 3 | Oracle OCI XA *shim* | `xa_oci` *defer*; produção: `DBMS_XA` | [PENDING](../Features/PENDING_IMPLEMENTATIONS.md) §1.2 — *checklist* *release* (confirmar política) |
| 4 | *Directed params* além do *MVP* + columnar v2 *evolution* | TVP, matriz `SqlDataType`×direcção, *benches*: só com prioridade de produto; certificação *driver* (TYPE_MAPPING) | PENDING §1.3–1.4, §2, [TYPE_MAPPING](TYPE_MAPPING.md) |
| — | *Infra* (TVP, E2E lentos, PG *OUT*) | *Guidance* / *opt-in*; TVP = *non-goal* até decisão; PG *OUT* = teste *host* | [docker-test-stack](../development/docker-test-stack.md) |

**Última actualização de índice:** 2026-04-24 (documentação *maturação*; PENDING
§1.1 *CI* DTC *live* *ad hoc*; governação OCI / *scope* TVP em §2).
