# BCP Nativo SQL Server - Research (F4.1 Etapa 1)

## Objetivo

Avaliar viabilidade de implementar BCP (Bulk Copy Program) nativo para SQL Server, em alternativa ao ArrayBinding atual, visando ganhos de performance em bulk inserts.

---

## 1. SQL Server BCP API

### O que é

BCP é uma API proprietária do SQL Server para transferência em massa de dados. Opera via extensões ODBC do SQL Server Native Client / ODBC Driver for SQL Server.

### Funções principais

| Função | Descrição |
|-------|-----------|
| `SQLSetConnectAttr(hdbc, SQL_COPT_SS_BCP, SQL_BCP_ON, SQL_IS_INTEGER)` | Habilita modo BCP **antes** de conectar |
| `bcp_init()` | Inicializa operação (DB_IN para import, DB_OUT para export) |
| `bcp_bind()` | Associa variáveis a colunas da tabela |
| `bcp_colfmt()` | Define formato de coluna e terminadores |
| `bcp_control()` | Define batch size e outras opções |
| `bcp_exec()` | Executa o bulk copy |
| `bcp_done()` | Finaliza e retorna linhas transferidas |

### Restrição crítica

`SQL_COPT_SS_BCP` deve ser definido **antes** de `SQLDriverConnect`. Ou seja, a conexão precisa ser alocada, o atributo BCP configurado, e só então a conexão estabelecida.

### Formatos

- **Native**: Tipos nativos do SQL Server, sem conversão. Mais rápido entre instâncias idênticas.
- **Character**: Texto delimitado.
- **Unicode**: Texto Unicode.

---

## 2. Disponibilidade em odbc-api

### Situação atual

- **odbc-api** não expõe `SQL_COPT_SS_BCP` nem as funções `bcp_*`.
- **odbc-api** usa `Environment::allocate_connection()` e em seguida `connect_with_connection_string()`. Não há hook para definir atributos SQL Server–específicos entre alocação e conexão.
- **Connection::into_handle()** permite obter o handle bruto, mas a conexão já está estabelecida — tarde demais para BCP.

### ColumnarBulkInserter

- `odbc-api` oferece `ColumnarBulkInserter` (array binding via `SQL_ATTR_PARAMSET_SIZE`).
- É o que usamos hoje via `ArrayBinding` e `bulk_copy_from_payload`.
- Não é BCP nativo; é INSERT parametrizado em batch.

---

## 3. Opções de implementação

### Opção A: Fork / PR em odbc-api

- Estender `ConnectionOptions` ou adicionar `connect_with_bcp(conn_str)` que:
  1. Aloca connection
  2. Chama `SQLSetConnectAttr(..., SQL_COPT_SS_BCP, SQL_BCP_ON, ...)`
  3. Conecta
- **Prós**: Integração limpa.
- **Contras**: Manutenção de fork ou dependência de PR upstream.

### Opção B: Caminho BCP via odbc-sys

- Usar `odbc-sys` (já dependência de `odbc-api`) para:
  1. Alocar env e connection
  2. Chamar `SQLSetConnectAttr` com `SQL_COPT_SS_BCP`
  3. `SQLDriverConnect`
  4. Chamar `bcp_*` via FFI (funções do driver SQL Server)
- **Prós**: Não depende de mudanças em odbc-api.
- **Contras**: `bcp_*` não estão em odbc-sys; é preciso carregar dinamicamente do driver (sqlncli / msodbcsql) ou definir bindings manualmente.

### Opção C: Manter ArrayBinding + ParallelBulkInsert

- Manter o fluxo atual: ArrayBinding + ParallelBulkInsert.
- Benchmarks mostram ~3.4x de ganho com parallel vs array em 1k–10k linhas.
- **Prós**: Já implementado, estável, sem dependências extras.
- **Contras**: Sem ganho adicional de BCP nativo.

---

## 4. Fallback strategy (recomendada)

1. **Curto prazo**: Manter fallback para ArrayBinding (já em uso).
2. **Médio prazo**: Se houver demanda por BCP nativo:
   - Avaliar PR em odbc-api para `SQL_COPT_SS_BCP` antes de conectar.
   - Ou implementar caminho BCP via odbc-sys + bindings manuais para `bcp_*`.
3. **Validação**: Benchmark BCP vs ArrayBinding em 100k+ linhas para medir ganho real.

---

## 5. Referências

- [bcp_control - Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-control)
- [bcp_bind - Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-extensions-bulk-copy-functions/bcp-bind)
- [Converting from DB-Library to ODBC Bulk Copy](https://learn.microsoft.com/en-us/sql/relational-databases/native-client-odbc-bulk-copy-operations/converting-from-db-library-to-odbc-bulk-copy)
- [odbc-api ColumnarBulkInserter](https://docs.rs/odbc-api/latest/odbc_api/struct.ColumnarBulkInserter.html)
- [Performance: BCP vs TVP vs Array Binding](https://stackoverflow.com/questions/2149897/performance-of-bcp-bulk-insert-vs-table-valued-parameters)

---

## 6. Conclusão

- **odbc-api** não suporta BCP nativo hoje.
- BCP exige `SQL_COPT_SS_BCP` antes da conexão; odbc-api não expõe esse ponto.
- **Fallback atual** (ArrayBinding + ParallelBulkInsert) é adequado e já oferece ganhos relevantes.
- Implementação de BCP nativo exigiria:
  - Extensão em odbc-api ou uso direto de odbc-sys, e
  - Bindings para `bcp_*` no driver SQL Server.
- **Recomendação**: Manter fallback; priorizar BCP nativo apenas se benchmarks em cenários reais (100k+ linhas) mostrarem ganho significativo (>2x) sobre ParallelBulkInsert.

---

## 7. Build com feature `sqlserver-bcp`

A feature `sqlserver-bcp` habilita o caminho `BulkCopyExecutor` com:
- Armazenamento de connection string (GlobalState) para tentativa de BCP nativo
- `bulk_copy_from_payload(conn, payload, conn_str)` — quando `conn_str` é `Some`, tenta BCP nativo
- Fallback automático para ArrayBinding quando BCP falha ou não está disponível
- `probe_native_bcp_support()` — detecta msodbcsql17/18, sqlncli11 e símbolos bcp_*

```bash
# Build com feature
cargo build --release --features sqlserver-bcp

# Dart/ffigen: incluir feature ao gerar bindings
# (o build.rs do projeto principal deve passar --features sqlserver-bcp se necessário)
```

**CI**: O workflow principal verifica `cargo build --release --features sqlserver-bcp` em todo push.
