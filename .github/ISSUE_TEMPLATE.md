# GitHub Issue Template

**Use este template para criar novas issues no rastreador do projeto.**

---

## Metadados Obligatórios

- **Tipo**: `Feature` | `Bug` | `Enhancement` | `Refactoring` | `Documentation`
- **Prioridade**: `P0` | `P1` | `P2`
- **Fase**: `Fase 0` | `Fase 1` | `Fase 2`
- **Escopo**: `Core` | `Plugin`

## Título

Título curto e descritivo em inglês (padrão GitHub).

**Exemplo**: `Add support for output parameters in prepared statements`

## Descrição

Descrição detalhada do que precisa ser implementado ou melhorado.

**Template**:
```
### Context
Background information about why this change is needed.

### Problem
What is the current limitation or issue?

### Solution
Proposed implementation approach.

### Alternatives Considered
Other options that were evaluated and why they were not chosen.

### Criteria
- [x] Implementation complete
- [x] Tests pass
- [x] Documentation updated
- [x] No breaking changes

### Related Files
List of files that were modified or created.

### References
Links to relevant documentation or similar implementations.
```

---

## Seções Adicionais (use conforme necessário)

### Implementation Details
Detalhes técnicos da implementação (opcional).

### Testing Strategy
Plano de testes (opcional).

### Breaking Changes
Mudanças que quebram compatibilidade com versões anteriores (se houver).

---

## Notas Importantes

1. **Referenciar issues do `doc/issues/`** quando criar a issue pública
2. **Adicionar links para arquivos de código** relacionados
3. **Mencionar fase e escopo** nos labels da issue
4. **Usar labels do projeto**: `phase-0`, `phase-1`, `phase-2`, `core`, `plugin`, `enhancement`, `bug`, `documentation`
5. **Marcar issue relacionada** no README/ROADMAP.md quando apropriado

---

## Labels Padrão do Projeto

**Fases:**
- `phase-0`: Fase 0 - Estabilização
- `phase-1`: Fase 1 - Paridade útil
- `phase-2`: Fase 2 - Expansão ODBC-first

**Escopos:**
- `core`: Funcionalidade portável entre drivers ODBC
- `plugin`: Funcionalidade específica de banco

**Tipos:**
- `enhancement`: Nova funcionalidade
- `bug`: Correção de bug
- `refactoring`: Reestruturação de código
- `documentation`: Atualização de documentação
- `performance`: Melhoria de performance

---

## Exemplo de Issue Completo

```markdown
# [REQ-005] Add request options per call

**Type**: `Feature`
**Priority**: `P1`
**Phase**: `Fase 1`
**Scope**: `Core`

### Description
Currently, timeout and buffer settings are global per connection. This limits fine-grained control and can lead to unexpected behavior in concurrent scenarios. Need to support per-request options similar to mssql package.

### Context
The mssql npm package supports `requestTimeout` and other options per Request instance. Our current implementation only allows setting these at connection level, which affects all queries indiscriminately.

### Problem
- Cannot set different timeouts for specific long-running queries
- Cannot control buffer size per request
- Unexpected behavior when multiple queries run concurrently

### Solution
Add an optional `RequestOptions` parameter to relevant methods (`executeQuery`, `executeQueryParams`, etc.) with properties like:
- `timeoutMs`: Override connection timeout for this specific request
- `maxBufferSize`: Maximum buffer size for this request result

### Criteria
- [ ] RequestOptions class/struct created
- [ ] Methods accept optional options parameter
- [ ] Tests pass with various timeout/buffer configurations
- [ ] Documentation updated
- [ ] No breaking changes to existing API

### Related Files
- `lib/domain/entities/request_options.dart` (new)
- `lib/application/services/odbc_service.dart` (modified)
- `native/odbc_engine/src/ffi/*.rs` (modified)
- `doc/issues/api/requests.md` (updated)

### References
- [mssql package - Requests](https://www.npmjs.com/package/mssql#requests)
- [Current implementation](lib/application/services/odbc_service.dart)

---

**Last updated**: 2026-02-11
```
