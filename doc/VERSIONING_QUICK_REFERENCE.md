# VERSIONING_QUICK_REFERENCE.md - Referência Rápida de Versionamento

Pocket guide for quick versioning decisions during development.

## Quick Decision: Which Bump?

Use this quick flowchart:

```
Mudança?
    │
    ├── Bug fix → PATCH (0.3.1 → 0.3.2)
    │
    ├── Nova feature? ──┬── Breaking API change?
    │                    │   ├── yes → MINOR (0.3.1 → 0.4.0) [Pré-1.0.0]
    │                    │   │        → MAJOR (1.0.0 → 2.0.0) [Pós-1.0.0]
    │                    │   │
    │                    │   └── not → PATCH (0.3.1 → 0.3.2)
    │                    │
    │                    └── Performance/Docs? → PATCH
    │
    ├── Remove feature? ──┼── Breaking → MINOR (0.3.1 → 0.4.0) [Pré-1.0.0]
    │                    │            → MAJOR (1.0.0 → 2.0.0) [Pós-1.0.0]
    │
    └── Deprecate feature → PATCH (nunca breaking)
```

## Matriz Resumida

### Pré-1.0.0 (0.x.x)

| Tipo             | example                | Bump            |
| ---------------- | ---------------------- | --------------- |
| **Breaking**     | remove método público | `0.4.0` (MINOR) |
| **Nova feature** | add método       | `0.3.2` (PATCH) |
| **Bug fix**      | Corrigir erro          | `0.3.2` (PATCH) |
| **Performance**  | Otimizar               | `0.3.2` (PATCH) |
| **Docs**         | update README       | `0.3.2` (PATCH) |
| **Deprecate**    | Marcar obsoleto        | `0.3.2` (PATCH) |

### Pós-1.0.0 (x.y.z)

| Tipo             | example                | Bump            |
| ---------------- | ---------------------- | --------------- |
| **Breaking**     | remove método público | `2.0.0` (MAJOR) |
| **Nova feature** | add método       | `1.1.0` (MINOR) |
| **Bug fix**      | Corrigir erro          | `1.0.1` (PATCH) |
| **Performance**  | Otimizar               | `1.0.1` (PATCH) |
| **Docs**         | update README       | `1.0.1` (PATCH) |
| **Deprecate**    | Marcar obsoleto        | `1.1.0` (MINOR) |

## Checklist Rápido de Breaking Change

A change is **BREAKING** if:

- ❌ Renomear método público ou classe
- ❌ Alterar tipo de retorno de método público
- ❌ remove parameter obrigatório de método público
- ❌ add parameter obrigatório a método público
- ❌ Alterar ordem de parameters de método público
- ❌ Alterar valor default de parameter
- ❌ remove classe, enum ou typedef público
- ❌ Tornar método público em privado
- ❌ Alterar tipo de parameter de método público

A change **not is breaking** if:

- ✅ add novo método público
- ✅ add new optional parameter (with default value)
- ✅ add nova classe ou enum
- ✅ Alterar implementação interna (mesma assinatura)
- ✅ Melhorar performance (mesma API)
- ✅ Melhorar mensagens de erro
- ✅ add documentation

## Tabela de Decisão por Componente

| Component | Change | Breaking? | Bump |
| -------------------- | ------------------------------ | --------- | ----------- |
| `Connection.execute` | Retorno: QueryResult → Result  | ✅ Yes    | MINOR/MAJOR |
| `Connection.execute` | parameter novo opcional        | ❌ No     | PATCH       |
| `Connection`         | remove método `closeLegacy()` | ✅ Yes    | MINOR/MAJOR |
| `Connection`         | add método `ping()`      | ❌ No     | PATCH       |
| `ConnectionOptions`  | Campo novo obrigatório         | ✅ Yes    | MINOR/MAJOR |
| `ConnectionOptions`  | Campo novo opcional            | ❌ No     | PATCH       |
| `Metrics`            | Alterar tipo de counter        | ✅ Yes    | MINOR/MAJOR |
| `Metrics`            | add novo counter         | ❌ No     | PATCH       |
| `AsyncError`         | Novo código de erro            | ❌ No     | PATCH       |
| `AsyncError`         | remove código de erro         | ✅ Yes    | MINOR/MAJOR |

## examples Práticos

### example 1: add parameter Opcional

```dart
// Antes
Future<QueryResult> execute(String sql);

// Depois
Future<QueryResult> execute(String sql, {Duration? timeout});
```

**Decisão**: ❌ not breaking → PATCH

**CHANGELOG**:

```markdown
## [0.3.2]

### Added

- **Connection.execute**: Added optional `timeout` parameter
```

---

### example 2: Renomear Método

```dart
// Antes
Future<QueryResult> execute(String sql);

// Depois
Future<QueryResult> executeQuery(String sql);
```

**Decisão**: ✅ Breaking → MINOR (pré-1.0.0)

**CHANGELOG**:

```markdown
## [0.4.0]

### Breaking Changes

- **Connection.execute**: Renamed to [executeQuery] for clarity
  - Migration: Replace all calls to `execute` with `executeQuery`
```

---

### example 3: Alterar Tipo de Retorno

```dart
// Antes
Future<QueryResult> execute(String sql);

// Depois
Future<Result<QueryResult, Error>> execute(String sql);
```

**Decisão**: ✅ Breaking → MINOR (pré-1.0.0)

**CHANGELOG**:

````markdown
## [0.4.0]

### Breaking Changes

- **Connection.execute**: Changed return type to Result for better error handling

  ```dart
  // Before
  final result = await conn.execute(sql);

  // After
  final result = await conn.execute(sql);
  result.fold(
    (queryResult) => /* success */,
    (error) => /* error */,
  );
  ```
````

````

---

### example 4: remove Método Deprecated

```dart
// Removido (deprecado em 0.2.0)
Future<QueryResult> executeLegacy(String sql);
````

**Decisão**: ✅ Breaking → MINOR (pré-1.0.0)

**CHANGELOG**:

```markdown
## [0.4.0]

### Removed

- **Connection.executeLegacy**: Removed. Use [execute] instead
  - Was deprecated in v0.2.0
```

---

### example 5: add Nova Feature

```dart
// Novo método
Future<void> executeBatch(List<String> sqls);
```

**Decisão**: ❌ not breaking → PATCH

**CHANGELOG**:

```markdown
## [0.3.2]

### Added

- **Connection.executeBatch**: Execute multiple SQL statements in batch
```

## Versionamento de Dependências

### Quando Mudar constraint de dependência?

| Situação                        | Ação                       |
| ------------------------------- | -------------------------- |
| Nova version com breaking change | Incrementar MAJOR ou MINOR |
| Nova version com features        | Mantenha `^` se compatível |
| Bug fix na dependência          | Mantenha `^`               |
| Security fix                    | Incrementar se necessário  |

**example**:

```yaml
# External dependency changed from 2.1.0 to 3.0.0 (breaking)
ffi: ^3.0.0 # ← If odbc_fast uses new breaking features

# External dependency changed from 2.1.0 to 2.2.0 (non-breaking)
ffi: ^2.1.0  # ← Mantenha, `^` permite 2.2.0
```

## Tags de Release

### Formato

```
v{MAJOR}.{MINOR}.{PATCH}[-{PRERELEASE}]

# examples
v0.4.0           # Release estável
v0.4.0-beta.1    # Beta release
v0.4.0-rc.1      # Release candidate
v0.4.0-dev.0     # mustlopment release
v1.0.0           # version 1.0.0
```

### Quando usar cada tipo?

| Tag             | Quando usar                                        |
| --------------- | -------------------------------------------------- |
| `vX.Y.Z`        | Release estável, ready para produção              |
| `vX.Y.Z-rc.N`   | Feature complete, API congelada, buscando feedback |
| `vX.Y.Z-beta.N` | Feature completa, mas com bugs conhecidos          |
| `vX.Y.Z-dev.N`  | Trabalho em progresso, APIs instáveis              |

## Comandos Úteis

### Verificar version atual

```bash
grep "version:" pubspec.yaml
```

### create tag de release

```bash
# Release estável
git tag -a v0.4.0 -m "Release v0.4.0"
git push origin v0.4.0

# Release candidate
git tag -a v1.0.0-rc.1 -m "Release candidate v1.0.0-rc.1"
git push origin v1.0.0-rc.1
```

### Verificar diff entre versões

```bash
git diff v0.3.1...v0.4.0
```

## Documentos Relacionados

- [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md) - Estratégia completa
- [CHANGELOG.md](../CHANGELOG.md) - Histórico de mudanças
- [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md) - Template de CHANGELOG
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md) - Processo de release automatizado



