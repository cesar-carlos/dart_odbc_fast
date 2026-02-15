# VERSIONING_STRATEGY.md - Estratégia de Versionamento

This document defines the **odbc_fast** versioning strategy, including guidelines for determining release types, support policy and roadmap for 1.0.0.

## Índice

- [Visão Geral](#visão-geral)
- [version Atual](#version-atual)
- [Matriz de Decisão de Versionamento](#matriz-de-decisão-de-versionamento)
- [Estratégia Pré-1.0.0](#estratégia-pré-1000)
- [Estratégia Pós-1.0.0](#estratégia-pós-1000)
- [Roadmap for 1.0.0](#roadmap-for-1000)
- [Tipos de Releases](#tipos-de-releases)
- [Política de Deprecation](#política-de-deprecation)
- [examples de Decisões de Versionamento](#examples-de-decisões-de-versionamento)

## Visão Geral

**odbc_fast** follows **Semantic Versioning 2.0.0** with Dart community specific convention for pre-1.0.0 versions.

### Convenção SemVer

```
MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]
```

| Componente     | Significado default (SemVer 2.0)             | Significado Pré-1.0.0 (Dart)                 |
| -------------- | ------------------------------------------- | -------------------------------------------- |
| **MAJOR**      | Breaking changes na API                     | not aplicável (x.0.0)                        |
| **MINOR** | New Features (backward compatible) | Breaking changes (scrolled down) |
| **PATCH**      | fixes de bugs (backward compatível)     | Novas Features/correkões not-breaking |
| **PRERELEASE** | `-alpha`, `-beta`, `-rc.1`, `-dev.0`        | Mesmo significado                            |

**example de deslocamento pré-1.0.0**:

```
0.3.0 → Breaking change na API (equivalente a 1.0.0 em SemVer default)
0.3.1 → Nova Feature not-breaking (equivalente a 1.0.1 em SemVer default)
0.3.2 → Correkção de bug (equivalente a 1.0.2 em SemVer default)
```

## version Atual

```yaml
version: 0.3.1
status: mustlopment (pre-1.0.0)
next_stable: 1.0.0
```

## Matriz de Decisão de Versionamento

Use this matrix to decide the type of version bump:

### Pré-1.0.0 (0.x.x)

| Tipo de Mudança               | example                      | Incremento | Tag      |
| ----------------------------- | ---------------------------- | ---------- | -------- |
| Breaking API change           | Renomear método público      | `0.4.0`    | `v0.4.0` |
| Remove Feature pública | remove método deprecated    | `0.4.0`    | `v0.4.0` |
| Mudança de tipo de retorno    | `Future<T>` → `Result<T, E>` | `0.4.0`    | `v0.4.0` |
| Nova Feature pública   | add novo método de API | `0.3.2`    | `v0.3.2` |
| Nova Feature interna   | Otimização de cache          | `0.3.2`    | `v0.3.2` |
| Correkão de bug               | Fixar race condition         | `0.3.2`    | `v0.3.2` |
| improvement de performance       | Reduzir latência de query    | `0.3.2`    | `v0.3.2` |
| documentation                  | update README/API docs    | `0.3.2`    | `v0.3.2` |

### Pós-1.0.0 (x.y.z)

| Tipo de Mudança               | example                      | Incremento        | Tag      |
| ----------------------------- | ---------------------------- | ----------------- | -------- |
| Breaking API change           | Renomear método público      | `1.0.0` → `2.0.0` | `v2.0.0` |
| Remove Feature pública | remove método deprecated    | `1.0.0` → `2.0.0` | `v2.0.0` |
| Mudança de tipo de retorno    | `Future<T>` → `Result<T, E>` | `1.0.0` → `2.0.0` | `v2.0.0` |
| Nova Feature pública   | add novo método de API | `1.0.0` → `1.1.0` | `v1.1.0` |
| Nova Feature interna   | Otimização de cache          | `1.0.0` → `1.0.1` | `v1.0.1` |
| Correkão de bug               | Fixar race condition         | `1.0.0` → `1.0.1` | `v1.0.1` |
| improvement de performance       | Reduzir latência de query    | `1.0.0` → `1.0.1` | `v1.0.1` |
| documentation                  | update README/API docs    | `1.0.0` → `1.0.1` | `v1.0.1` |

## Estratégia Pré-1.0.0

### Current Phase: 0.3.x - Active Development

**Características**:

- API em evolução rápida
- Breaking changes esperados e comunicados
- Foco em Features principais
- Performance e estabilidade sendo otimizadas

**Guidelines**:

- ✅ Use **MINOR increments** (`0.4.0`, `0.5.0`) for breaking changes
- ✅ Use **PATCH increments** (`0.3.2`, `0.3.3`) for non-breaking features/fixes
- ✅ Documente claramente breaking changes em CHANGELOG.md
- ✅ Use prerelease tags (`-beta.1`, `-rc.1`) for testing before official release
- ✅ Always include migration examples for breaking changes

**example de CHANGELOG Pré-1.0.0**:

````markdown
## [0.4.0] - 2026-02-15

### Breaking Changes

- **AsyncNativeOdbcConnection.execute**: Changed return type from `Future<QueryResult>` to `Future<Result<QueryResult, AsyncError>>`
  - Migration: Wrap calls with `.fold(...)` or `.getOrElse(...)`

  ```dart
  // Before
  final result = await conn.execute('SELECT * FROM users');

  // After
  final result = await conn.execute('SELECT * FROM users');
  result.fold(
    (queryResult) => print('Success: ${queryResult.rowCount} rows'),
    (error) => print('Error: ${error.message}'),
  );
  ```
````

- **ConnectionOptions**: Removed `defaultTimeout` parameter. Use `requestTimeout` instead.
  - Migration: Replace `defaultTimeout: Duration(seconds: 30)` with `requestTimeout: Duration(seconds: 30)`

### Added

- Result type with comprehensive error handling
- New error codes: `requestTimeout`, `workerTerminated`

### Fixed

- Race condition in worker isolate disposal

```

## Estratégia Pós-1.0.0

### Fase: 1.x.y - API Estável

**Características**:
- API pública congelada (backward compatibility garantida)
- Breaking changes extremamente raros
- Foco em performance, features e correkções
- Suporte de longo prazo (LTS)

**Guidelines**:

- ✅ Use **MAJOR increments** (`2.0.0`, `3.0.0`) APENAS para breaking changes
- ✅ Use **MINOR increments** (`1.1.0`, `1.2.0`) para novas features
- ✅ Use **PATCH increments** (`1.0.1`, `1.0.2`) para bugs e otimizações
- ✅ Use **deprecation period** mínimo de 2 MINOR releases antes de remove
- ✅ Sempre inclua guia de migração para breaking changes

**Deprecation Policy**:

```

version A.B.0 → Deprecate Feature
version A.B+1.0 → Marcar como deprecated em docs
version A.B+2.0 → remove Feature breaking change

```

**example**:

```

v1.0.0 → Introduzir método X
v1.2.0 → Deprecate método X (add @Deprecated)
v1.4.0 → remove método X (v2.0.0 breaking change)

```

## Roadmap para 1.0.0

O 1.0.0 é lançado quando a API pública está estabilizada e pronta para uso em produção.

### Checklist de Pré-1.0.0

Antes de lançar 1.0.0, verifique:

#### API e Features

- [ ] **API Pública Completa**: Todas as Features principais implementadas
  - [ ] connections (sync e async)
  - [ ] Queries (execukão, streaming)
  - [ ] Prepared statements
  - [ ] Transakções e savepoints
  - [ ] Bulk operations
  - [ ] Connection pooling
  - [ ] Telemetry/metrics

- [ ] **API Estável**: Nenhum breaking change planejado nos próximos 3-6 meses
- [ ] **API Consistente**: Nomes de métodos, tipos de retorno, parameters consistentes
- [ ] **Type Safety**: Tipagem correta em toda API pública

#### Testes

- [ ] **Cobertura de Testes Unitários**: >80% na Domain Layer
- [ ] **Testes de integration**: Todos os principais fluxos cobertos
- [ ] **Testes E2E**: Scenarios end-to-end para Windows e Linux
- [ ] **Performance Tests**: Benchmarks para operações críticas
- [ ] **Testes de Stress**: Comportamento sob carga alta

#### documentation

- [ ] **README**: Guia completo de instalação e primeiros passos
- [ ] **API Docs**: documentation completa via dart doc comments (`///`)
- [ ] **examples**: examples executáveis para Features principais
- [ ] **CHANGELOG**: Histórico de mudanças bem mantido
- [ ] **Migration Guide**: Guia de migração de 0.x.x para 1.0.0

#### Estabilidade e Performance

- [ ] **Sem Memory Leaks**: Verificado com Valgrind/ASAN (Rust) e Dart DevTools
- [ ] **Performance Aceitável**: Benchmarks dentro de limites aceitáveis
- [ ] **Error Handling**: Mensagens de erro claras e acionáveis
- [ ] **Platform Support**: Windows e Linux x86_64 estáveis

#### Segurança

- [ ] **Dependências Atualizadas**: Sem dependências vulneráveis conhecidas
- [ ] **FFI Safety**: Validar boundaries e tipos no FFI
- [ ] **Input Validation**: Validar todos os inputs externos

### Planos de Releases Pré-1.0.0

```

0.3.x → 0.4.0 (Breaking changes se necessários)
0.4.x → 0.5.0 (Polish e otimizações)
0.5.x → 0.6.0-rc.1 (Release Candidate)
0.6.0-rc.2 → Feedback e correkões
0.6.0-rc.3 → Validakão final
1.0.0 → Release estável

```

## Tipos de Releases

### Release Estável (Production)

**Tag**: `vX.Y.Z` (ex: `v0.4.0`, `v1.0.0`)

**Uso**:
- ready para produção
- API estável e testada
- Suporte completo

**Processo**:
1. Checklist de release completo
2. Testes em staging
3. Tag e push
4. GitHub Actions cria release
5. Publicação no pub.dev

### Release Candidate (RC)

**Tag**: `vX.Y.Z-rc.N` (ex: `v1.0.0-rc.1`, `v1.0.0-rc.2`)

**Uso**:
- next de produção
- API congelada
- Buscando feedback final

**Processo**:
1. Feature complete
2. Testes em staging
3. Tag `-rc.1`
4. Feedback da comunidade
5. Correkões se necessário (`-rc.2`, `-rc.3`)
6. Release estável se OK

### Beta Release

**Tag**: `vX.Y.Z-beta.N` (ex: `v0.4.0-beta.1`)

**Uso**:
- Feature completa mas com bugs conhecidos
- API pode mudar
- Testing de Features principais

**Processo**:
1. Feature implementada
2. Testes unitários passando
3. Tag `-beta.1`
4. Feedback e correkões
5. RC quando estável

### Alpha/Dev Release

**Tag**: `vX.Y.Z-dev.N` (ex: `v0.4.0-dev.0`, `v0.4.0-alpha.1`)

**Uso**:
- Trabalho em progresso
- APIs instáveis
- Testing interno ou early adopters

**Processo**:
1. Feature em desenvolvimento
2. Build manual
3. Tag `-dev.N`
4. not publicar no pub.dev

## Política de Deprecation

### Ciclo de Vida de Feature

```

┌─────────────┐
│ Stable │ ← Feature introduzida
└──────┬──────┘
│
▼
┌─────────────┐
│ Deprecated │ ← Anunciada como deprecated (doc + @Deprecated)
└──────┬──────┘ (período de deprecation: 2 MINOR releases)
│
▼
┌─────────────┐
│ Removed │ ← Removida (MAJOR version bump)
└─────────────┘

````

### Guidelines de Deprecation

**Quando deprecate**:

- ✅ Quando Feature será substituída por algo melhor
- ✅ Quando Feature é raramente usada
- ✅ Quando Feature causa problemas de performance

**Como deprecate**:

```dart
/// @Deprecated('Use [executeAsync] instead. Will be removed in v2.0.0')
Future<QueryResult> execute(String sql) async {
  // implementation
}
````

**CHANGELOG entry**:

```markdown
## [1.2.0] - 2026-03-01

### Deprecated

- **AsyncNativeOdbcConnection.execute**: Use [executeAsync] instead. Will be removed in v2.0.0.
```

**Migration guide**:

````markdown
## Migration Guide: v1.2.0 → v2.0.0

### execute → executeAsync

The [execute] method has been removed. Use [executeAsync] instead.

**Before**:

```dart
final result = await conn.execute('SELECT * FROM users');
```
````

**After**:

```dart
final result = await conn.executeAsync('SELECT * FROM users');
```

````

## examples de Decisões de Versionamento

### example 1: add Nova Feature (Pré-1.0.0)

**Scenario**: add `executeBatch` method for bulk insert.

**Decisão**: `0.3.1` → `0.3.2` (PATCH increment)

**Razão**: Nova Feature pública, backward compatível.

**CHANGELOG**:

```markdown
## [0.3.2] - 2026-02-15

### Added

- **Connection.executeBatch**: Execute multiple queries in a single batch operation
  ```dart
  await conn.executeBatch([
    'INSERT INTO users (name) VALUES (?)',
    'INSERT INTO users (name) VALUES (?)',
  ], params: [
    ['Alice'],
    ['Bob'],
  ]);
````

````

### example 2: Breaking API Change (Pré-1.0.0)

**Scenario**: Change `execute` return from `Future<QueryResult>` to `Future<Result<QueryResult, QueryError>>`.

**Decisão**: `0.3.2` → `0.4.0` (MINOR increment)

**Razão**: Breaking change na API pública.

**CHANGELOG**:

```markdown
## [0.4.0] - 2026-02-20

### Breaking Changes

- **Connection.execute**: Changed return type from `Future<QueryResult>` to `Future<Result<QueryResult, QueryError>>`
  - This provides better error handling and type safety
  - Migration:
    ```dart
    // Before
    final result = await conn.execute('SELECT * FROM users');
    if (result.error != null) {
      throw Exception(result.error);
    }

    // After
    final result = await conn.execute('SELECT * FROM users');
    result.fold(
      (queryResult) => print('Rows: ${queryResult.rowCount}'),
      (error) => print('Error: ${error.message}'),
    );
    ```
````

### example 3: Correkão de Bug (Pós-1.0.0)

**Cenário**: Fixar memory leak em streaming queries.

**Decisão**: `1.0.0` → `1.0.1` (PATCH increment)

**Razão**: Correkão de bug, backward compatível.

**CHANGELOG**:

```markdown
## [1.0.1] - 2026-03-01

### Fixed

- **Memory leak**: Fixed memory leak in streaming queries when rows are not fully consumed
  - Ensure to complete streams or call `Stream.cancel()` to release resources
```

### example 4: Breaking API Change (Pós-1.0.0)

**Cenário**: remove método deprecated `executeBatch` e substituir por `executeBulk`.

**Decisão**: `1.2.0` → `2.0.0` (MAJOR increment)

**Razão**: Breaking change na API pública estável.

**CHANGELOG**:

````markdown
## [2.0.0] - 2026-06-01

### Breaking Changes

- **Connection.executeBatch**: Removed. Use [executeBulk] instead.
  - [executeBatch] was deprecated in v1.2.0
  - Migration:

    ```dart
    // Before
    await conn.executeBatch([
      'INSERT INTO users (name) VALUES (?)',
      'INSERT INTO users (name) VALUES (?)',
    ], params: [
      ['Alice'],
      ['Bob'],
    ]);

    // After
    await conn.executeBulk('INSERT INTO users (name) VALUES (?)', [
      ['Alice'],
      ['Bob'],
    ]);
    ```

### Added

- **Connection.executeBulk**: More efficient bulk insert API with automatic batching
````

## Recursos Adicionais

- [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)
- [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
- [Dart Versioning](https://dart.dev/tools/pub/versioning)
- [Dart Publishing](https://dart.dev/tools/pub/publishing)
- [CHANGELOG.md](../CHANGELOG.md)
- [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)



