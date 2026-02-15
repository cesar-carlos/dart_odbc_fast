# Implementações Futuras

Itens documentados e deixados para implementação futura. not bloqueiam o uso atual do pacote.

---

## 1. Bulk Insert Paralelo (`odbc_bulk_insert_parallel`)

### Estado atual

| Camada            | Situação                                                                                                                                                                                                                                                        |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Rust FFI**      | `odbc_bulk_insert_parallel` existe como **stub**: sempre returns -1 e grava erro "use engine ParallelBulkInsert API". Em `native/odbc_engine/src/ffi/mod.rs`.                                                                                                   |
| **Rust engine**   | `ParallelBulkInsert` em `native/odbc_engine/src/engine/core/parallel_insert.rs`: usa pool + rayon, divide dados em chunks e insere em paralelo. Hoje expõe `insert_i32_parallel(table, columns, data)` (tipado para i32). not consome o payload binário do FFI. |
| **Dart bindings** | `odbc_bulk_insert_parallel` é feito lookup em `lib/infrastructure/native/bindings/odbc_bindings.dart`.                                                                                                                                                          |
| **Dart API**      | Nenhum método em OdbcNative, repositório ou service chama essa função. Só existe `bulkInsertArray` → `odbc_bulk_insert_array`.                                                                                                                                  |

### Uso atual de bulk insert

O fluxo em produção é uma única connection:

- `OdbcService.bulkInsert(connectionId, table, columns, data, rowCount)` → repositório → `bulkInsertArray` → `odbc_bulk_insert_array`.
- Atende cargas típicas (dezenas/centenas de milhares de linhas).

### Quando faria sentido implementar

- Cargas muito grandes (milhões de linhas).
- Pool já utilizado; ganho seria throughput (tempo total), not nova capacidade.
- Prioridade **baixa** frente a Schema PK/FK/Indexes e queryTimeout global.

### Para implementação futura

1. **Rust:** Expor pool por `pool_id` no estado global do FFI; adaptar ou create caminho que use o payload binário (como em `odbc_bulk_insert_array`) e chame a lógica de `ParallelBulkInsert` (ou equivalente genérico).
2. **Dart:** add algo como `bulkInsertParallel(poolId, table, columns, data, parallelism)` em OdbcNative e, se desejado, em repositório/serviço.
3. Manter compatibilidade com a API atual de bulk insert por connection.

**Referências de código:** `native/odbc_engine/src/ffi/mod.rs` (stub), `native/odbc_engine/src/engine/core/parallel_insert.rs`, `native/odbc_engine/tests/e2e_bulk_operations_test.rs`.

---

## 2. Schema Reflection PK/FK/Indexes

### Estado atual

- Entidades Dart: `PrimaryKeyInfo`, `ForeignKeyInfo`, `IndexInfo` em `lib/domain/entities/schema_info.dart`.
- Catálogo básico já existe: `catalogTables`, `catalogColumns`, `catalogTypeInfo` (Rust + FFI + Dart).

### pending para implementação futura

- Rust: `list_primary_keys`, `list_foreign_keys`, `list_indexes`.
- FFI: `odbc_catalog_primary_keys`, etc.
- Dart: métodos no repositório/serviço e testes.

---

## 3. queryTimeout global

### Estado atual

- **Implementado.** `ConnectionOptions.queryTimeout` é aplicado em `executeQuery`, `executeQueryParams` e `executeQueryMulti` em [lib/infrastructure/repositories/odbc_repository_impl.dart](lib/infrastructure/repositories/odbc_repository_impl.dart). Quando definido, o fluxo completo da operação é envolvido em `Future.timeout`; ao estourar, returns `Failure(QueryError(message: 'Query timed out'))`. `null` ou `Duration.zero` mantém o comportamento sem limite.

---

## Prioridade sugerida

1. Schema PK/FK/Indexes (alto valor para muitos cenários).
2. Bulk insert paralelo (somente se houver demanda por cargas massivas).



