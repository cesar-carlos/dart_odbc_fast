# CHANGELOG_TEMPLATE.md - Template for CHANGELOG

This template serves as a guide to keep [CHANGELOG.md](../CHANGELOG.md) consistent and complete, following the default [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Formato default

````markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Item 1

### Changed

- Item 1

### Deprecated

- Item 1

### Removed

- Item 1

### Fixed

- Item 1

### Security

- Item 1

## [0.4.0] - 2026-02-15

### Breaking Changes

- **API Component**: Description with migration guide

  ```dart
  // Before
  final result = await conn.execute(sql);

  // After
  final result = await conn.execute(sql);
  result.fold(/* ... */);
  ```
````

### Added

- **New Feature**: Description with example

### Changed

- **Modified Feature**: Description

### Fixed

- **Bug Fix**: Description

### Performance

- **Optimization**: Description with metrics

[0.4.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.0...v0.3.1

````

## Categorias de Mudanças

### Added (Adicionado)

Novas Features, métodos, classes, ou parameters.

**examples**:

```markdown
### Added

- **Connection.executeBatch**: Execute multiple queries in a single batch operation
- **ConnectionOptions.requestTimeout**: Optional timeout per request (default: 30s)
- **Metrics.newConnectionCounter**: Counter for tracking new connections
````

### Changed (Alterado)

Mudanças em Features existentes que são backward compatíveis.

**examples**:

```markdown
### Changed

- **Connection.execute**: Improved performance by caching prepared statements
- **AsyncNativeOdbcConnection**: Now uses more efficient message serialization
- **Download retry**: Increased maximum retry attempts from 2 to 3
```

### Deprecated (Deprecado)

Features marcadas para remoção em versões futuras.

**examples**:

```markdown
### Deprecated

- **Connection.executeLegacy**: Use [execute] instead. Will be removed in v1.0.0
- **Metrics.enable**: Use [Metrics.configure] instead. Will be removed in v0.5.0
```

### Removed (Removido)

Features removidas da API (sempre breaking change).

**examples**:

```markdown
### Removed

- **Connection.executeLegacy**: Removed. Use [execute] instead
```

### Fixed (Corrigido)

fixes de bugs.

**examples**:

```markdown
### Fixed

- **Async API**: Pending requests now complete with error when connection is disposed
- **BinaryProtocolParser**: Fixed buffer overflow error for large result sets
- **Memory leak**: Fixed memory leak in streaming queries when not fully consumed
```

### Performance (Performance)

Otimizações de performance (opcional, pode ser incluído em "Changed").

**examples**:

```markdown
### Performance

- **Query execution**: Reduced overhead by 30% by optimizing serialization
- **Connection pooling**: Improved pool reuse rate, reducing connection creation time
- **Stream processing**: Reduced memory usage by 40% for large result sets
```

### Security (Segurança)

fixes de segurança ou improvements de segurança.

**examples**:

```markdown
### Security

- **Input validation**: Added validation for SQL injection prevention
- **FFI bounds**: Added strict bounds checking for FFI buffers
```

## Como Documentar Breaking Changes

Breaking changes requerem documentation especial:

1. **Título destacado**: Use **Negrito** para o componente alterado
2. **Descrição clara**: Explique o que mudou e por quê
3. **Guia de migração**: Sempre inclua example de como migrar
4. **Motivação**: Explique o benefício da mudança

**example completo**:

````markdown
## [0.4.0] - 2026-02-15

### Breaking Changes

- **AsyncNativeOdbcConnection.execute**: Changed return type from `Future<QueryResult>` to `Future<Result<QueryResult, AsyncError>>`
  - This change provides comprehensive error handling with typed error codes
  - Migration:

    ```dart
    // Before
    final result = await conn.execute('SELECT * FROM users');
    if (result.error != null) {
      print('Error: ${result.error}');
    }

    // After
    final result = await conn.execute('SELECT * FROM users');
    result.fold(
      (queryResult) => print('Rows: ${queryResult.rowCount}'),
      (error) => print('Error: ${error.code}: ${error.message}'),
    );
    ```
````

## Como Documentar Novas Features

Para novas Features, inclua:

1. **Nome destacado**: Use **Negrito** para o componente
2. **Descrição**: O que faz e para que serve
3. **example**: Código de example se not-trivial

**example**:

````markdown
### Added

- **Connection.executeBatch**: Execute multiple queries in a single batch operation for improved performance
  - Reduces round trips to the database
  - Example:
    ```dart
    await conn.executeBatch([
      'INSERT INTO users (name) VALUES (?)',
      'INSERT INTO users (name) VALUES (?)',
    ], params: [
      ['Alice'],
      ['Bob'],
    ]);
    ```
````

## Como Documentar fixes de Bugs

Para fixes de bugs, inclua:

1. **Nome destacado**: Use **Negrito** para o componente afetado
2. **Descrição**: O que estava errado e como foi corrigido
3. **Impacto**: Se afetava muitos users, mencione

**example**:

```markdown
### Fixed

- **Async API "No error" bug**: When executing queries with no parameters, worker isolate returned "No error" instead of success
  - Fixed by always passing a valid buffer to native bindings
  - Affected all parameterless queries (CREATE TABLE, INSERT, etc.)
```

## Links de version

No final do CHANGELOG, mantenha links para comparação entre versões:

```markdown
[0.4.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.2.9...v0.3.0
```

## Processo de Atualização

1. add mudanças na seção `[Unreleased]` durante desenvolvimento
2. Antes do release, create nova seção com a version atual
3. Mover itens de `[Unreleased]` para a nova seção
4. add link de comparação no final
5. create nova seção `[Unreleased]` vazia

**example de workflow**:

```bash
# Durante desenvolvimento
git commit -m "feat: add executeBatch method"
# add a [Unreleased] → Added → Connection.executeBatch

# Antes do release
git commit -m "chore: prepare release 0.4.0"
# 1. create nova seção: ## [0.4.0] - 2026-02-15
# 2. Move items from [Unreleased] to [0.4.0]
#3. add link: [0.4.0]: https://github.com/.../compare/v0.3.1...v0.4.0
# 4. create nova [Unreleased] vazia
```

## Checklist Antes do Release

Antes de fazer release, verifique:

- [ ] Todos os itens relevantes estão no CHANGELOG
- [ ] Breaking changes estão destacados e com guia de migração
- [ ] Novas Features têm examples
- [ ] Correkões de bugs explicam o impacto
- [ ] Links de version estão atualizados
- [ ] Data da version está correta
- [ ] Formato segue o default Keep a Changelog

## examples de CHANGELOG Reais

### example: Patch Release (0.3.2)

```markdown
## [0.3.2] - 2026-02-15

### Added

- **Connection.executeBatch**: Execute multiple queries in a single batch operation
- **Metrics.batchExecutionTime**: Track batch execution duration

### Fixed

- **Memory leak**: Fixed memory leak in streaming queries when not fully consumed

### Performance

- **Serialization**: Reduced message serialization overhead by 20%

[0.3.2]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.3.2
```

### example: Minor/Breaking Release (0.4.0)

````markdown
## [0.4.0] - 2026-02-20

### Breaking Changes

- **AsyncNativeOdbcConnection.execute**: Changed return type from `Future<QueryResult>` to `Future<Result<QueryResult, AsyncError>>`
  - Migration:

    ```dart
    // Before
    final result = await conn.execute(sql);

    // After
    final result = await conn.execute(sql);
    result.fold(
      (queryResult) => print('Rows: ${queryResult.rowCount}'),
      (error) => print('Error: ${error.message}'),
    );
    ```

### Added

- **AsyncError**: New error type with codes: `requestTimeout`, `workerTerminated`
- **ConnectionOptions.requestTimeout**: Optional timeout per request (default: 30s)

### Removed

- **QueryError**: Replaced by AsyncError with more granular error codes

[0.4.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v0.3.1...v0.4.0
````

### example: Major Release (2.0.0)

````markdown
## [2.0.0] - 2026-06-01

### Breaking Changes

- **Connection API**: Complete redesign of Connection interface
  - [Connection.execute] now returns Result instead of throwing exceptions
  - [Connection.query] renamed to [executeQuery] for clarity
  - Migration guide available in docs/MIGRATION_1_TO_2.md

- **Telemetry API**: yesplified telemetry configuration
  - [Telemetry.configure] replaces [Telemetry.enable]
  - Migration:

    ```dart
    // Before
    Telemetry.enable(console: true, file: 'telemetry.log');

    // After
    Telemetry.configure(
      exporters: [ConsoleExporter(), FileExporter('telemetry.log')],
    );
    ```

### Added

- **Observability**: OpenTelemetry integration out of the box
- **Connection pooling**: Built-in connection pool with configurable size
- **Streaming API**: Reactive streams for real-time query results

### Deprecated

- **Metrics API**: Will be replaced by Telemetry in v2.1.0

### Removed

- **Legacy sync API**: Removed synchronous API methods
- **QueryError**: Replaced by TypedError with more granular error types

[2.0.0]: https://github.com/cesar-carlos/dart_odbc_fast/compare/v1.2.0...v2.0.0
````

## Recursos

- [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
- [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
- [Dart Versioning](https://dart.dev/tools/pub/versioning)
- [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)



