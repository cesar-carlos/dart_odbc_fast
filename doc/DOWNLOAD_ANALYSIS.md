# DOWNLOAD_ANALYSIS.md - analysis do Processo de Download da DLL

## Visão Geral

This document analyzes the native library (DLL/OS) download flow when a user runs `dart pub get` on the `odbc_fast` package.

## Fluxo Atual

### 1. Momento do Download

The download happens **during** `dart pub get`, via the Native Assets hook in `hook/build.dart`.

### 2. Estratégia de Resolução da Biblioteca

The `_getLibraryPath()` function in `hook/build.dart` follows this priority order:

```
1. Cache Local (~/.cache/odbc_fast/<version>/)
   └─ Se existe: returns caminho cacheado ✓

2. Build Local de Desenvolvimento
   ├─ native/target/release/<libname> (workspace)
   └─ native/odbc_engine/target/release/<libname> (local)
      └─ Se existe: returns caminho de dev ✓

3. Download do GitHub Release
   └─ https://github.com/cesar-carlos/dart_odbc_fast/releases/download/v<version>/<libname>
      ├─ Se CI/pub.dev: PULA (evita timeout na analysis)
      ├─ Se success: baixa, cacheia, returns caminho ✓
      └─ Se failure: returns null ✗

4. Retorno Null
   └─ Permite que testes continuem sem biblioteca
```

### 3. Cache por version

The cache is organized by version to avoid conflicts:

```
~/.cache/odbc_fast/
├── 0.2.7/
│   ├── windows_x64/odbc_engine.dll
│   └── linux_x64/libodbc_engine.so
├── 0.3.0/
│   ├── windows_x64/odbc_engine.dll
│   └── linux_x64/libodbc_engine.so
```

## Problemas Identificados

### 🔴 Críticos

#### 1. Release Inexistente Causa failure Silenciosa

**Problem**: If the GitHub Release for the current version does not exist yet (e.g. during development of a new version), the hook returns `null` and no assets are registered.

**Impacto**:

- user recebe erro em tempo de execution: `"ODBC engine library not found"`
- Error message does not explain that the release does not exist

**Solução sugerida**:

```dart
Future<Uri?> _downloadFromGitHub(...) async {
  if (_shouldSkipDownload()) {
    return null;
  }

  try {
    // ... download logic ...
    if (response.statusCode == 404) {
      print('[odbc_fast] WARNING: Release v$version not found on GitHub.');
      print('[odbc_fast] This is expected during mustlopment. For production,');
      print('[odbc_fast] ensure the release exists: ');
      print('[odbc_fast] https://github.com/cesar-carlos/dart_odbc_fast/releases');
      return null;
    }
    // ...
  } catch (e) {
    print('[odbc_fast] Download failed: $e');
    return null;
  }
}
```

#### 2. Sem Verificação de Integridade (Checksum)

**Issue**: The hook downloads the DLL without checking whether the file was downloaded correctly or whether it was corrupted during the download.

**Riscos**:

- Download corrompido causa crash em tempo de execution
- Possibility of MITM attack (although low probability with HTTPS)

**Solução sugerida**: add verificação SHA-256

```dart
// No pubspec.yaml ou arquivo separado:
# native_assets_checksums:
#   version: "0.3.0"
#   windows_x64: "sha256:abc123..."
#   linux_x64: "sha256:def456..."

// No build.dart:
Future<Uri?> _downloadFromGitHub(...) async {
  // ... download ...
  await sink.close();

  // Verificar checksum
  final expectedChecksum = _getExpectedChecksum(os, arch, version);
  if (expectedChecksum != null) {
    final actualChecksum = await _computeSha256(targetFile);
    if (actualChecksum != expectedChecksum) {
      print('[odbc_fast] ERROR: Checksum mismatch!');
      await targetFile.delete();
      return null;
    }
  }

  return targetFile.uri;
}
```

### 🟡 Médios

#### 3. Erro de Rede Sem Retry

**Problem**: If there is a temporary network failure, the download fails immediately without trying again.

**Suggested solution**: add retry with exponential backoff

```dart
Future<Uri?> _downloadFromGitHub(...) async {
  const maxRetries = 3;
  int attempt = 0;

  while (attempt < maxRetries) {
    try {
      // ... download attempt ...
      return targetFile.uri;
    } on IOException catch (e) {
      attempt++;
      if (attempt >= maxRetries) {
        print('[odbc_fast] Download failed after $maxRetries attempts: $e');
        return null;
      }
      final delay = Duration(milliseconds: 100 * (1 << attempt));
      print('[odbc_fast] Retry $attempt/$maxRetries after ${delay.inSeconds}s');
      await Future.delayed(delay);
    }
  }
  return null;
}
```

#### 4. Sem Timeout Configurável

**Problema**: `HttpClient` not tem timeout, pode travar indefinidamente em connections lentas.

**Solução sugerida**:

```dart
final client = HttpClient();
client.connectionTimeout = Duration(seconds: 30);

final request = await client.getUrl(Uri.parse(url));
// ...
```

#### 5. Mensagens de Erro Pouco Informativas

**Problem**: When the download fails, the message does not clearly explain what the user should do.

**Solução sugerida**: Melhorar mensagens de erro

```dart
} catch (e) {
  print('[odbc_fast] Failed to download native library.');
  print('[odbc_fast] Version: $version, Platform: ${_osToString(os)}_${_archToString(arch)}');
  print('[odbc_fast] Error: $e');
  print('[odbc_fast]');
  print('[odbc_fast] Troubleshooting:');
  print('[odbc_fast] 1. Check your internet connection');
  print('[odbc_fast] 2. Verify the release exists:');
  print('[odbc_fast]    https://github.com/cesar-carlos/dart_odbc_fast/releases');
  print('[odbc_fast] 3. For mustlopment, build locally:');
  print('[odbc_fast]    cd native/odbc_engine && cargo build --release');
  return null;
}
```

### 🟢 Menores

#### 6. Barra de Progresso Falta

**Issue**: user does not have visual feedback when downloading the DLL (~1 MB).

**Suggested solution**: add progress indicator (depends on `package:http` with streaming).

## Usage Scenarios

### Cenário 1: user Final (Produção)

```bash
$ dart pub add odbc_fast
Resolving dependencies...
+ odbc_fast 0.3.0
[odbc_fast] Downloading native library from https://github.com/.../odbc_engine.dll
[odbc_fast] Downloaded to C:\Users\...\.cache\odbc_fast\0.3.0\windows_x64\odbc_engine.dll
Got dependencies!
```

**Status**: ✓ Works well

### Cenário 2: Desenvolvimento do Pacote

```bash
$ cd dart_odbc_fast
$ dart pub get
Resolving dependencies...
Got dependencies!
# not faz download porque encontra em native/target/release/
```

**Status**: ✓ Works well

### Cenário 3: Primeiro `pub get` Após Release Nova

```bash
$ dart pub get
[odbc_fast] Downloading native library from https://github.com/.../releases/download/v0.3.1/odbc_engine.dll
[odbc_fast] Failed to download: HTTP 404
# Erro em runtime: "ODBC engine library not found"
```

**Status**: ✗ Problem - release does not exist yet

### Cenário 4: pub.dev Analysis

```bash
# pub.dev executa o hook durante analysis
$ PUB_ENVIRONMENT="pub.dev" dart pub get
# Hook detecta Environment e PULA download
# analysis continua sem timeout
```

**Status**: ✓ Works well (after our fix)

## recommendations

### Imediatas (Antes da next Release)

1. **Melhorar mensagens de erro** quando release not existe (404)
2. **add timeout** to HttpClient
3. **Document** clearly in the README that the release must exist first

### Curto Prazo (Próximas Versões)

1. Implement **retry with exponential backoff**
2. add **verificação de checksum**
3. create **script de verificação** pós-download

### Longo Prazo

1. Consider using **package:http** instead of `HttpClient` for better streaming/progress support
2. Implement **fallback for alternative URLs** (e.g. AWS S3, CDN)
3. Add **anonymous telemetry** to understand download failures

## Conclusão

The current flow works well for most scenarios, but there are some areas that could be improved:

**Pontos Fortes**:

- ✓ Cache por version evita conflitos
- ✓ Supports local build for development
- ✓ Detecta e pula download em CI/pub.dev

**Pontos a Melhorar**:

- ✗ Sem verificação de integridade
- ✗ Sem retry em caso de failure de rede
- ✗ Mensagens de erro podem ser mais claras
- ✗ Sem feedback visual de progresso

The highest priority is to improve error messages, especially when the release does not exist, so that developers know what to do.



