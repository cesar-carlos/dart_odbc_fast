# Scripts Python Cross-Platform

Todos os scripts PowerShell e Bash foram convertidos para Python para suporte cross-platform (Windows, Linux, macOS).

## Requisitos

- Python 3.7 ou superior
- Rust/Cargo (para scripts que compilam código nativo)
- Dart SDK (para scripts que executam testes Dart)

## Scripts Disponíveis

### 🔨 Build

```bash
# Build completo (Rust + FFI bindings)
python scripts/build.py

# Pular build do Rust (apenas bindings)
python scripts/build.py --skip-rust

# Pular geração de bindings (apenas Rust)
python scripts/build.py --skip-bindings
```

**Substitui**: `build.ps1`, `build.sh`

---

### 🧪 Testes

#### Todos os Testes

```bash
# Build Rust + executar todos os testes
python scripts/test_all.py

# Pular build do Rust
python scripts/test_all.py --skip-rust

# Usar concorrência (mais rápido)
python scripts/test_all.py --concurrency 4
```

**Substitui**: `test_all.ps1`

#### Testes Nativos (Rust)

```bash
# Testes Rust em modo debug
python scripts/test_native.py

# Testes Rust em modo release
python scripts/test_native.py --release

# Apenas testes FFI
python scripts/test_native.py --ffi-only
```

**Substitui**: `test_native.ps1`

#### Testes End-to-End

```bash
# Requer ODBC_TEST_DSN e ENABLE_E2E_TESTS configurados
python scripts/test_e2e.py
```

**Substitui**: `test_e2e.ps1`

#### Testes Unitários (Dart)

```bash
# Testes que não requerem ODBC nativo
python scripts/test_unit.py
```

**Substitui**: `test_unit.ps1`

---

### ✅ Validação

#### Validação Completa

```bash
# Valida Rust + Dart + artefatos
python scripts/validate_all.py

# Apenas verificar artefatos
python scripts/validate_all.py --artifacts-only
```

**Substitui**: `validate_all.ps1`

#### Validação Native Assets

```bash
# Valida configuração do hook/build.dart
python scripts/validate_native_assets.py
```

**Substitui**: `validate_native_assets.ps1`

---

### 📦 Release

```bash
# Criar tag e push para GitHub
python scripts/create_release.py 1.2.0

# Criar tag sem push
python scripts/create_release.py 1.2.0 --no-push
```

**Substitui**: `create_release.ps1`

---

### 📋 Utilitários

```bash
# Copiar DLL do package para projeto
python scripts/copy_odbc_dll.py

# Especificar diretório do projeto
python scripts/copy_odbc_dll.py --project-root /path/to/project
```

**Substitui**: `copy_odbc_dll.ps1`

---

## Execução no Linux/macOS

Torne os scripts executáveis:

```bash
chmod +x scripts/*.py
```

Depois você pode executar diretamente:

```bash
./scripts/build.py
./scripts/test_all.py --concurrency 4
```

## Cores no Terminal

Os scripts usam códigos ANSI para colorir a saída:
- 🟦 Cabeçalhos (Ciano)
- 🟨 Etapas/Steps (Amarelo)
- 🟩 Sucesso (Verde)
- 🟥 Erro (Vermelho)
- ⬜ Informações (Cinza)

Se o terminal não suportar cores, elas são automaticamente desabilitadas.

## Compatibilidade

| Script | Windows | Linux | macOS |
|--------|---------|-------|-------|
| build.py | ✅ | ✅ | ✅ |
| test_all.py | ✅ | ✅ | ✅ |
| test_native.py | ✅ | ✅ | ✅ |
| test_e2e.py | ✅ | ✅ | ✅ |
| test_unit.py | ✅ | ✅ | ✅ |
| validate_all.py | ✅ | ✅ | ✅ |
| validate_native_assets.py | ✅ | ✅ | ✅ |
| create_release.py | ✅ | ✅ | ✅ |
| copy_odbc_dll.py | ✅ | ✅ | ✅ |

## Migrando dos Scripts Antigos

| Script Antigo | Script Python Novo |
|---------------|-------------------|
| `.\scripts\build.ps1` | `python scripts/build.py` |
| `bash scripts/build.sh` | `python scripts/build.py` |
| `.\scripts\test_all.ps1` | `python scripts/test_all.py` |
| `.\scripts\test_native.ps1` | `python scripts/test_native.py` |
| `.\scripts\test_e2e.ps1` | `python scripts/test_e2e.py` |
| `.\scripts\test_unit.ps1` | `python scripts/test_unit.py` |
| `.\scripts\validate_all.ps1` | `python scripts/validate_all.py` |
| `.\scripts\validate_native_assets.ps1` | `python scripts/validate_native_assets.py` |
| `.\scripts\create_release.ps1` | `python scripts/create_release.py` |
| `.\scripts\copy_odbc_dll.ps1` | `python scripts/copy_odbc_dll.py` |

## Vantagens dos Scripts Python

1. **Cross-platform**: Um único script funciona em Windows, Linux e macOS
2. **Manutenibilidade**: Código mais simples e unificado
3. **Menor duplicação**: Não precisa manter versões .ps1 e .sh separadas
4. **Bibliotecas padrão**: Usa apenas bibliotecas Python padrão (sem dependências externas)
5. **Tipagem**: Usa type hints para melhor documentação do código

## Troubleshooting

### Python não encontrado

**Windows**:
```powershell
# Instalar Python
winget install Python.Python.3.12
```

**Linux**:
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install python3

# Fedora
sudo dnf install python3
```

**macOS**:
```bash
# Usando Homebrew
brew install python3
```

### Permissão negada no Linux/macOS

```bash
chmod +x scripts/*.py
```

### Cores não aparecem

Alguns terminais não suportam ANSI colors. Os scripts detectam automaticamente e desabilitam cores nesses casos.

## Estrutura do Código

Todos os scripts seguem a mesma estrutura:

1. **Imports**: Bibliotecas Python padrão
2. **Colors class**: Classe para colorização da saída
3. **Helper functions**: Funções auxiliares reutilizáveis
4. **main()**: Lógica principal do script
5. **CLI argument parsing**: argparse para opções de linha de comando

## Contribuindo

Ao adicionar novos scripts:

1. Use Python 3.7+ (para suporte amplo)
2. Use apenas bibliotecas padrão quando possível
3. Adicione docstring no topo do arquivo
4. Use type hints para parâmetros e retornos
5. Implemente `--help` via argparse
6. Mantenha o estilo de cores consistente
7. Teste em Windows, Linux e macOS

## Referências

- [Python argparse](https://docs.python.org/3/library/argparse.html)
- [Python pathlib](https://docs.python.org/3/library/pathlib.html)
- [Python subprocess](https://docs.python.org/3/library/subprocess.html)
- [ANSI escape codes](https://en.wikipedia.org/wiki/ANSI_escape_code)
