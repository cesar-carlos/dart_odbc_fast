# Roadmap: itens ainda abertos

**Fonte de verdade:** [`PENDING_IMPLEMENTATIONS.md`](../Features/PENDING_IMPLEMENTATIONS.md).

Este arquivo e apenas um indice curto para priorizacao. Nao duplicar detalhe
aqui — atualize PENDING e o CHANGELOG quando um item fechar.

| Ordem | Tema | Estado | Proximo passo |
| ----- | ---- | ------ | ------------- |
| 1 | MSDTC / `xa-dtc` recovery avancado | Lifecycle basico entregue (`xa-dtc`); `Reenlist` / recovery de RM fora do crate | PENDING §2.1 + smokes Windows opt-in |
| 2 | Oracle `SYS_REFCURSOR` maturacao | Motor + wire + Dart entregues | Certificar drivers live (PENDING §2.2) |
| 3 | Columnar v2 default/bench | Encodings entregues; row-major permanece default | Benchmarks live antes de trocar default (PENDING §2.3) |
| 4 | OCI XA shim | Scaffold `xa-oci`; produto usa `DBMS_XA` | PENDING §3.1 |
| 5 | TVP / matriz `SqlDataType` x direcao | Produto-gated | Fechar [`TVP_DESIGN_GATE.md`](TVP_DESIGN_GATE.md) |
| - | E2E host-side | Testes opt-in | [`TESTING.md`](../TESTING.md) |

**Entregue (nao listar como aberto):** sharding completo do `GlobalState`
residual (`env` + BCP strings) — ver CHANGELOG Unreleased / PERFORMANCE.

Ultima atualizacao: 2026-07-31 (pacote `4.5.0`).
