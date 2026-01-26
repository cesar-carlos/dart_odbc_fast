# Próximos Passos - Native Assets Implementation

## Status Atual

✅ **Implementação Completa**
- Hook `hook/build.dart` criado e validado
- `pubspec.yaml` configurado com Native Assets
- `library_loader.dart` atualizado com suporte a Native Assets
- Workflow de release `.github/workflows/release.yml` criado
- Documentação criada

## Passo 1: Compilar Biblioteca Rust

Antes de testar o Native Assets, é necessário compilar a biblioteca Rust:

```bash
cd native/odbc_engine
cargo build --release
```

**Windows:**
```powershell
cd native\odbc_engine
cargo build --release
```

Isso gerará:
- Windows: `native/odbc_engine/target/release/odbc_engine.dll`
- Linux: `native/odbc_engine/target/release/libodbc_engine.so`
- macOS: `native/odbc_engine/target/release/libodbc_engine.dylib`

## Passo 2: Testar Hook Localmente

Após compilar o Rust, teste o hook:

```bash
dart run hook/build.dart
```

**Nota:** O hook pode falhar se a biblioteca não estiver compilada, mas isso é esperado.
O erro deve indicar claramente que a biblioteca precisa ser compilada primeiro.

## Passo 3: Validar com Script

Execute o script de validação:

**Windows:**
```powershell
.\scripts\validate_native_assets.ps1
```

**Linux/macOS:**
```bash
# Criar versão bash se necessário
chmod +x scripts/validate_native_assets.sh
./scripts/validate_native_assets.sh
```

## Passo 4: Executar Testes

Certifique-se de que todos os testes passam:

```bash
dart test
```

Os testes devem funcionar normalmente, carregando a biblioteca do caminho de desenvolvimento.

## Passo 5: Criar Primeira Release

Quando estiver pronto para criar a primeira release com binários:

### 5.1 Preparar Release

1. Atualizar `CHANGELOG.md` com as mudanças
2. Verificar que a versão em `pubspec.yaml` está correta
3. Commitar todas as mudanças

### 5.2 Criar Tag e Push

```bash
git tag v0.1.0
git push origin v0.1.0
```

Isso acionará automaticamente o workflow `.github/workflows/release.yml` que:
1. Compilará o Rust para todas as plataformas (Windows, Linux, macOS Intel, macOS ARM)
2. Criará um GitHub Release com todos os binários
3. Os binários estarão disponíveis para download

### 5.3 Verificar Release

1. Acesse: https://github.com/cesar-carlos/dart_odbc_fast/releases
2. Verifique que a release `v0.1.0` foi criada
3. Confirme que os binários estão anexados:
   - `x86_64-pc-windows-msvc/odbc_engine.dll`
   - `x86_64-unknown-linux-gnu/libodbc_engine.so`
   - `x86_64-apple-darwin/libodbc_engine.dylib`
   - `aarch64-apple-darwin/libodbc_engine.dylib`

## Passo 6: Testar Instalação Limpa

Para validar que o Native Assets funciona em produção:

### 6.1 Criar Projeto de Teste

```bash
mkdir test_installation
cd test_installation
dart create .
```

### 6.2 Adicionar Dependência

No `pubspec.yaml` do projeto de teste:

```yaml
dependencies:
  odbc_fast:
    git:
      url: https://github.com/cesar-carlos/dart_odbc_fast.git
      ref: v0.1.0
```

Ou após publicar no pub.dev:

```yaml
dependencies:
  odbc_fast: ^0.1.0
```

### 6.3 Instalar e Testar

```bash
dart pub get
dart run
```

O Native Assets deve:
1. Detectar a plataforma
2. Baixar o binário correto do GitHub Release (ou usar bundled)
3. Carregar a biblioteca automaticamente

## Passo 7: Publicar no pub.dev

Após validar que tudo funciona:

### 7.1 Preparar Publicação

```bash
# Validar package
dart pub publish --dry-run

# Verificar que não há arquivos desnecessários
# O .pubignore deve estar configurado corretamente
```

### 7.2 Publicar

```bash
dart pub publish
```

**Nota:** O pub.dev não hospeda binários grandes. Os binários devem ser:
- Baixados via GitHub Releases (recomendado)
- Ou incluídos como assets no package (limite de tamanho)

## Troubleshooting

### Hook falha com "Native library not found"

**Causa:** Biblioteca Rust não compilada ou caminho incorreto.

**Solução:**
1. Compile o Rust: `cd native/odbc_engine && cargo build --release`
2. Verifique que o arquivo existe no caminho esperado
3. Para produção, certifique-se de que os binários estão no GitHub Release

### Native Assets não baixa binários

**Causa:** GitHub Release não criado ou binários não anexados.

**Solução:**
1. Verifique que a release existe: https://github.com/cesar-carlos/dart_odbc_fast/releases
2. Confirme que os binários estão anexados à release
3. Verifique os nomes dos arquivos (devem corresponder aos esperados pelo hook)

### Erro ao carregar biblioteca em produção

**Causa:** Binário não encontrado ou incompatível com a plataforma.

**Solução:**
1. Verifique que o binário correto foi baixado para sua plataforma
2. Confirme que ODBC drivers estão instalados
3. Verifique logs de erro para mais detalhes

## Referências

- [Dart Native Assets Documentation](https://dart.dev/tools/hooks)
- [Native Assets CLI](https://pub.dev/packages/native_assets_cli)
- [GitHub Actions Release Workflow](.github/workflows/release.yml)
- [Native Assets Implementation Guide](doc/NATIVE_ASSETS.md)
