# GitHub Issue Template

**Use this template to create new issues in the project tracker.**

---

## Metadados ObligatÃ³rios

- **Tipo**: `Feature` | `Bug` | `Enhancement` | `Refactoring` | `Documentation`
- **Priority**: `P0` | `P1` | `P2`
- **Phase**: `Phase 0` | `Phase 1` | `Phase 2`
- **Escopo**: `Core` | `Plugin`

## TÃ­tulo

Short and descriptive title in English (GitHub standard).

**Example**: `Add support for output parameters in prepared statements`

## Description

Detailed description of what needs to be implemented or improved.

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

## SeÃ§Ãµes Adicionais (use conforme necessÃ¡rio)

### Implementation Details
Technical implementation details (optional).

### Testing Strategy
Plano de testes (opcional).

### Breaking Changes
Changes that break compatibility with previous versions (if any).

---

## Notas Importantes

1. **Referenciar issues do `doc/issues/`** quando create a issue pÃºblica
2. **Add links to related code files**
3. **Mention phase and scope** in the issue labels
4. **Use project labels**: `phase-0`, `phase-1`, `phase-2`, `core`, `plugin`, `enhancement`, `bug`, `documentation`
5. **Mark related issue** in README/ROADMAP.md when appropriate

---

## Project Standard Labels

**Phases:**
- `phase-0`: Phase 0 - Stabilization
- `phase-1`: Phase 1 - Useful parity
- `phase-2`: Phase 2 - ODBC-first Expansion

**Escopos:**
- `core`: feature portÃ¡vel entre drivers ODBC
- `plugin`: feature especÃ­fica de banco

**Tipos:**
- `enhancement`: Nova feature
- `bug`: Bug fix
- `refactoring`: Code restructuring
- `documentation`: Documentation update
- `performance`: Performance improvement

---

## Complete Issue Example

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

