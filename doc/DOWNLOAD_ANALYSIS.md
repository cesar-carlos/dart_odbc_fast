# DOWNLOAD_ANALYSIS.md - Análise do Processo de Download da DLL

## Visão Geral

Este documento analisa o fluxo de download da biblioteca nativa (DLL/SO) quando um usuário executa `dart pub get` no pacote `odbc_fast`.

## Fluxo Atual

### 1. Momento do Download

O download acontece **durante** `dart pub get`, através do hook de Native Assets em `hook/build.dart`.

### 2. Estratégia de Resolução da Biblioteca

A função `_getLibraryPath()` em `hook/build.dart` segue esta ordem de prioridade:

```
1. Cache Local (~/.cache/odbc_fast/<version>/)
   └─ Se existe: retorna caminho cacheado ✓

2. Build Local de Desenvolvimento
   ├─ native/target/release/<libname> (workspace)
   └─ native/odbc_engine/target/release/<libname> (local)
      └─ Se existe: retorna caminho de dev ✓

3. Download do GitHub Release
   └─ https://github.com/cesar-carlos/dart_odbc_fast/releases/download/v<version>/<libname>
      ├─ Se CI/pub.dev: PULA (evita timeout na análise)
      ├─ Se sucesso: baixa, cacheia, retorna caminho ✓
      └─ Se falha: retorna null ✗

4. Retorno Null
   └─ Permite que testes continuem sem biblioteca
```

### 3. Cache por Versão

O cache é organizado por versão para evitar conflitos:

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

#### 1. Release Inexistente Causa Falha Silenciosa

**Problema**: Se a GitHub Release para a versão atual não existir ainda (ex: durante desenvolvimento de nova versão), o hook retorna `null` e nenhum asset é registrado.

**Impacto**:
- Usuário recebe erro em tempo de execução: `"ODBC engine library not found"`
- Mensagem de erro não explica que a release não existe

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
      print('[odbc_fast] This is expected during development. For production,');
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

**Problema**: O hook baixa a DLL sem verificar se o arquivo foi baixado corretamente ou se foi corrompido durante o download.

**Riscos**:
- Download corrompido causa crash em tempo de execução
- Possibilidade de ataque MITM (embora baixa probabilidade com HTTPS)

**Solução sugerida**: Adicionar verificação SHA-256
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

**Problema**: Se houver falha temporária de rede, o download falha imediatamente sem tentar novamente.

**Solução sugerida**: Adicionar retry com exponential backoff
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

**Problema**: `HttpClient` não tem timeout, pode travar indefinidamente em conexões lentas.

**Solução sugerida**:
```dart
final client = HttpClient();
client.connectionTimeout = Duration(seconds: 30);

final request = await client.getUrl(Uri.parse(url));
// ...
```

#### 5. Mensagens de Erro Pouco Informativas

**Problema**: Quando o download falha, a mensagem não explica claramente o que o usuário deve fazer.

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
  print('[odbc_fast] 3. For development, build locally:');
  print('[odbc_fast]    cd native/odbc_engine && cargo build --release');
  return null;
}
```

### 🟢 Menores

#### 6. Barra de Progresso Falta

**Problema**: Usuário não tem feedback visual durante o download da DLL (~1 MB).

**Solução sugerida**: Adicionar progress indicator (depende de `package:http` com streaming).

## Cenários de Uso

### Cenário 1: Usuário Final (Produção)

```bash
$ dart pub add odbc_fast
Resolving dependencies...
+ odbc_fast 0.3.0
[odbc_fast] Downloading native library from https://github.com/.../odbc_engine.dll
[odbc_fast] Downloaded to C:\Users\...\.cache\odbc_fast\0.3.0\windows_x64\odbc_engine.dll
Got dependencies!
```

**Status**: ✓ Funciona bem

### Cenário 2: Desenvolvimento do Pacote

```bash
$ cd dart_odbc_fast
$ dart pub get
Resolving dependencies...
Got dependencies!
# Não faz download porque encontra em native/target/release/
```

**Status**: ✓ Funciona bem

### Cenário 3: Primeiro `pub get` Após Release Nova

```bash
$ dart pub get
[odbc_fast] Downloading native library from https://github.com/.../releases/download/v0.3.1/odbc_engine.dll
[odbc_fast] Failed to download: HTTP 404
# Erro em runtime: "ODBC engine library not found"
```

**Status**: ✗ Problema - release não existe ainda

### Cenário 4: pub.dev Analysis

```bash
# pub.dev executa o hook durante análise
$ PUB_ENVIRONMENT="pub.dev" dart pub get
# Hook detecta ambiente e PULA download
# Análise continua sem timeout
```

**Status**: ✓ Funciona bem (após nossa correção)

## Recomendações

### Imediatas (Antes da Próxima Release)

1. **Melhorar mensagens de erro** quando release não existe (404)
2. **Adicionar timeout** ao HttpClient
3. **Documentar** claramente no README que a release deve existir primeiro

### Curto Prazo (Próximas Versões)

1. Implementar **retry com exponential backoff**
2. Adicionar **verificação de checksum**
3. Criar **script de verificação** pós-download

### Longo Prazo

1. Considerar usar **package:http** ao invés de `HttpClient` para melhor suporte a streaming/progresso
2. Implementar **fallback para URLs alternativas** (ex: AWS S3, CDN)
3. Adicionar **telemetria anônima** para entender falhas de download

## Conclusão

O fluxo atual funciona bem para a maioria dos cenários, mas tem algumas áreas que podem ser melhoradas:

**Pontos Fortes**:
- ✓ Cache por versão evita conflitos
- ✓ Suporta build local para desenvolvimento
- ✓ Detecta e pula download em CI/pub.dev

**Pontos a Melhorar**:
- ✗ Sem verificação de integridade
- ✗ Sem retry em caso de falha de rede
- ✗ Mensagens de erro podem ser mais claras
- ✗ Sem feedback visual de progresso

A prioridade mais alta é **melhorar as mensagens de erro**, especialmente quando a release não existe, para que desenvolvedores saibam o que fazer.
