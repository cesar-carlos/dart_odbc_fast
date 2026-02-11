# REQ-001 - Multi-Result End-to-End

**Status**: Pending (Fase 1 - P1)

**Última Atualização**: 2026-02-11

---

## Objetivo

Implementar suporte a multi-result sets retornados por operações ODBC no Dart FFI.

## Escopo

Esta issue abrange:

### 1. Payload Multi-Result

- Especificar formato binário para transmissão eficiente de dados multi-result entre Rust FFI e Dart
- Definir estruturas de dados para: Result Set, Row Count, Metadata

### 2. Cenários de Uso

- **SELECT** com stored procedures que retornam múltiplos result sets
- **INSERT/UPDATE** em massa com resultado único (row count)
- **DDL** com resultado de metadados

### 3. Estratégia de Parsing

- Iteração sobre resultados vindos da FFI
- Extração de metadados (colunas, tipos, row count)
- Validação de consistência dos dados

## Design do Payload

### Estrutura Binária Proposta

```rust
// Multi-Result Payload
struct MultiResultPayload {
    // Header
    version: u8,           // Versão do protocolo
    result_count: u8,      // Número de resultados (Result Sets)
    reserved: [u8; 256], // Bytes reservados para extensão

    // Result Sets (variados)
    results: Vec<MultiResultSet>, // Tamanho dinâmico baseado em result_count
}

struct MultiResultSet {
    has_data: bool,        // Se contém linhas de dados
    row_count: u64,        // Número de linhas afetadas
    metadata_size: u16,    // Tamanho dos metadados
    data: Vec<u8>,       // Dados binários das linhas/metadata
}

// Exemplo de codificação
// Header (5 bytes): [version, count, reserved0...4]
// ResultSet 1: [has_data=1, row_count=2, metadata_size=8, data=...]
```

### Dependências

- `protocol/decoder.rs` - Parser de payloads binários
- `protocol/multi_result.rs` - Tipos de dados multi-result
- FFI: `odbc_exec_query_multi()` - Função FFI existente

## Critérios de Aceitação

- ✅ Payload binário eficiente e bem definido
- ✅ Estratégia clara de parsing (iteração sobre dados retornados)
- ✅ Compatibilidade com ODBC SQLMoreResults
- ✅ Testes de integração cobrindo todos os cenários

## Referências

- `doc/issues/api/requests.md` - Contexto geral de requests
- `doc/issues/api/transactions.md` - Padrões de transação ODBC
- ODBC API: `SQLMoreResults` e `SQLNumResultSets`

---

**Co-Autores**: @claude-sonnet-4.5
**Revisão Pendente**: A especificar detalhes do payload e estratégia de parsing
