# Roadmap: itens ainda abertos

Lista operacional derivada de
[`PENDING_IMPLEMENTATIONS`](../Features/PENDING_IMPLEMENTATIONS.md). O objetivo
e ordenar trabalho real: itens entregues ficam na documentacao canonica; itens
abaixo exigem ambiente live, maturacao ou decisao de produto.

| Ordem | Tema | Estado | Proximo passo |
| ----- | ---- | ------ | ------------- |
| 1 | MSDTC / `xa-dtc` recovery avancado | Lifecycle basico entregue no Windows com `--features xa-dtc`; `Reenlist` / recovery de RM fora do crate | Rodar smokes opt-in em host Windows e abrir design separado se recovery automatico virar requisito |
| 2 | Oracle `SYS_REFCURSOR` maturacao | Motor + wire + Dart entregues (`strip ?`, `SQLMoreResults`, `RC1\0`) | Certificar drivers reais e ampliar E2E opt-in conforme aparecerem regressions |
| 3 | Columnar v2 default/bench | `ResultEncoding.columnar` e `columnarCompressed` entregues; row-major segue default | Benchmarks live por workload antes de qualquer troca de default |
| 4 | OCI XA shim | Scaffold `xa_oci`; produto usa `DBMS_XA` | Reabrir apenas se houver API segura para compartilhar sessao OCI/ODBC |
| 5 | TVP / `SqlDataType` x direcao completa | Produto-gated; sem API publica | Fechar [`TVP_DESIGN_GATE.md`](TVP_DESIGN_GATE.md) antes de implementar |
| - | E2E host-side | Testes existem e sao opt-in | Manter runbooks para DSN/driver local; nao colocar no CI Ubuntu padrao |

Ultima atualizacao: 2026-05-25.
