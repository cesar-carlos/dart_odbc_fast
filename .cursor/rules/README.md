# Cursor Rules - Usage Guide

This directory contains Cursor rules to maintain code consistency and quality. The rules are organized into **generic** (reusable) and **project-specific**.

## ðŸ“ File Structure

```
.cursor/rules/
â”œâ”€â”€ README.md                 # Este arquivo
â”œâ”€â”€ rules_index.mdc          # Ãndice completo das regras
â”‚
â”œâ”€â”€ ðŸ”„ REGRAS GENÃ‰RICAS (ReutilizÃ¡veis)
â”‚   â”œâ”€â”€ general_rules.mdc        # Regras gerais e princÃ­pios fundamentais
â”‚   â”œâ”€â”€ clean_architecture.mdc   # Regras genÃ©ricas de Clean Architecture (camadas/dependÃªncias)
â”‚   â”œâ”€â”€ solid_principles.mdc     # PrincÃ­pios SOLID
â”‚   â”œâ”€â”€ coding_style.mdc         # Guia de estilo Dart 2026
â”‚   â”œâ”€â”€ null_safety.mdc          # Boas prÃ¡ticas de null safety
â”‚   â”œâ”€â”€ testing.mdc              # PadrÃµes de testes
â”‚   â”œâ”€â”€ flutter_widgets.mdc      # Widgets Flutter (estrutura/performance/layout/tokens)
â”‚   â”œâ”€â”€ ui_ux_design.mdc         # PrincÃ­pios de UI/UX para desktop
â”‚   â””â”€â”€ rust_style.mdc           # PadrÃµes de Rust nativo (fmt/clippy/FFI)
â”‚   â””â”€â”€ error_handling.mdc       # Tratamento de erro e polÃ­tica de supressÃ£o
â”‚
â””â”€â”€ ðŸŽ¯ REGRAS ESPECÃFICAS
    â””â”€â”€ project_specifics.mdc    # Regras especÃ­ficas deste projeto
```

## ðŸ”„ Copying Rules to Other Projects

### 1. Regras GenÃ©ricas (Copie TUDO)

These rules are **100% reusable** in any Flutter/Dart project:

âœ… **Copie estes arquivos sem modificaÃ§Ãµes:**

- `rules_index.mdc`
- `general_rules.mdc`
- `clean_architecture.mdc`
- `solid_principles.mdc`
- `coding_style.mdc`
- `null_safety.mdc`
- `testing.mdc`
- `flutter_widgets.mdc`
- `ui_ux_design.mdc` (se for app desktop)
- `rust_style.mdc` (if there is Rust code in the project)
- `error_handling.mdc`

### 2. Regras EspecÃ­ficas (Adapte)

This file needs to be **adapted** for each project:

âš ï¸ **Adapt this file:**

- `project_specifics.mdc` - Adjust for your project

### Como Adaptar `project_specifics.mdc`

Open the file and modify:

1. **Project Type**: Type of your project (Desktop App, Mobile App, Web App)
2. **Architecture**: Arquitetura usada (Clean Architecture, MVVM, Simple, etc.)
3. **Project Dependencies**: Dependencies specific to your project
4. **Project Structure**: Estrutura de pastas
5. **Entry Point Pattern**: Initialization pattern
6. **Data Flow**: Specific data flow
7. **Patterns Used**: Patterns used in the project

## ðŸ“‹ Usage Example

### For a new project with Clean Architecture:

```bash
# 1. Copie todos os arquivos genÃ©ricos
cp -r .cursor/rules/*.mdc /seu-novo-projeto/.cursor/rules/

# 2. Edite apenas project_specifics.mdc
# Ajuste: arquitetura, dependÃªncias, estrutura
```

### For a new project with simple architecture:

```bash
# 1. Copie todos os arquivos genÃ©ricos
cp -r .cursor/rules/*.mdc /seu-novo-projeto/.cursor/rules/

# 2. Simplifique project_specifics.mdc
# Remova: regras de Clean Architecture, camadas complexas
# Mantenha: dependÃªncias, padrÃµes simples
```

## âœ¨ Contents of Generic Rules

### `general_rules.mdc`

- Fundamental principles (concise code, composition, naming)
- Documentation rules (do not create automatic docs)
- CÃ³digo autoexplicativo
- Evitar nÃºmeros mÃ¡gicos
- Priorizar componentes reutilizÃ¡veis

### `solid_principles.mdc`

- Single Responsibility Principle (SRP)
- Open/Closed Principle (OCP)
- Liskov Substitution Principle (LSP)
- Interface Segregation Principle (ISP)
- Dependency Inversion Principle (DIP)
- Examples and common violations

### `coding_style.mdc`

- ConvenÃ§Ãµes de nomenclatura (2026)
- Type declaration
- Const constructors
- Arrow syntax e expression bodies
- Trailing commas
- Import organization
- FunÃ§Ãµes e mÃ©todos (< 20 linhas)
- Recursos modernos do Dart 3+ (Pattern matching, Records, Switch expressions)

### `null_safety.mdc`

- Nullable vs non-nullable
- Null-aware operators (`?.`, `??`, `??=`)
- Variable initialization
- Null checks
- APIs externas

### `testing.mdc`

- Estrutura de testes (Unit, Widget)
- AAA pattern (Arrange, Act, Assert)
- Nomenclatura de testes
- Mocking e isolamento
- package:checks for assertions

### `flutter_widgets.mdc`

- Stateless vs Stateful
- Widget composition (private classes, not methods)
- Performance (const, ListView.builder, RepaintBoundary)
- Material 3 theming
- Layout e responsividade
- Tear-offs for widgets

### `ui_ux_design.mdc`

- Hierarquia visual
- Color palette (60-30-10 rule)
- Typography
- Desktop navigation
- Feedback mechanisms
- Accessibility (WCAG 2.1 AA)
- Responsive design
- Keyboard navigation

### `rust_style.mdc`

- ConvenÃ§Ãµes oficiais de estilo Rust
- `cargo fmt`/rustfmt e Clippy
- API Guidelines for crates
- Boas prÃ¡ticas de erro (`Result`, sem `unwrap` indevido)
- FFI security (`#[repr(C)]`, panics do not cross FFI)

### `error_handling.mdc`

- Regra transversal de tratamento de erro (Dart + Rust)
- Prohibition of suppressing diagnoses outside the allowlist
- Propagation rules with context
- Deletion templates with reason + issue + removal deadline

## ðŸŽ¯ Ajustando Globs

If your folder structure is different, adjust the `globs` in frontmatter:

```yaml
---
description: DescriÃ§Ã£o da regra
globs: ["seu_path/**/*.dart"] # Ajuste aqui
alwaysApply: true
---
```

**Adjustment examples:**

```yaml
# Se usar lib/screens/ ao invÃ©s de lib/pages/
globs: ["lib/screens/**/*.dart", "lib/widgets/**/*.dart"]

# Se usar lib/features/ ao invÃ©s de lib/presentation/
globs: ["lib/features/**/*.dart"]

# Se usar lib/modules/
globs: ["lib/modules/**/*.dart"]
```

## ðŸ“š ReferÃªncias

- [Cursor Documentation on Rules](https://docs.cursor.com/en/context/rules)
- [Flutter AI Rules](https://docs.flutter.dev/ai/ai-rules)
- [Effective Dart: Style Guide](https://dart.dev/effective-dart/style)
- [SOLID Principles](https://en.wikipedia.org/wiki/SOLID)
- [Material 3 Guidelines](https://m3.material.io/)
- [Rust Style Guide](https://doc.rust-lang.org/style-guide/)
- [rustfmt](https://rust-lang.github.io/rustfmt/)
- [Rust Clippy](https://doc.rust-lang.org/clippy/)
- [Dart Error Handling](https://dart.dev/language/error-handling)
- [Rust std::error](https://doc.rust-lang.org/std/error/)

## ðŸ” Quick Check

After copying the rules to a new project:

- [ ] All generic `.mdc` files were copied
- [ ] `project_specifics.mdc` has been adapted for the new project
- [ ] Globs foram ajustados se necessÃ¡rio
- [ ] Arquitetura estÃ¡ corretamente documentada
- [ ] Dependencies are listed
- [ ] Estrutura de pastas estÃ¡ documentada

## ðŸ’¡ Dicas

1. **Keep the generic rules without modifications** - they are based on best practices
2. **Adapt only project_specifics.mdc** - each project is unique
3. **Revise rules_index.mdc** periodicamente - mantenha atualizado
4. **Test the rules** - Cursor will automatically apply when working on files
5. **Share knowledge** - use these rules as a reference for the team

## ðŸš€ Quick Start for New Project

```bash
# 1. Crie a pasta de regras
mkdir -p /seu-projeto/.cursor/rules

# 2. Copie os arquivos genÃ©ricos
cp general_rules.mdc solid_principles.mdc coding_style.mdc \
   null_safety.mdc testing.mdc flutter_widgets.mdc rust_style.mdc error_handling.mdc \
   ui_ux_design.mdc rules_index.mdc \
   /seu-projeto/.cursor/rules/

# 3. Copie e adapte as regras especÃ­ficas
cp project_specifics.mdc /seu-projeto/.cursor/rules/

# 4. Edite project_specifics.mdc no seu editor
code /seu-projeto/.cursor/rules/project_specifics.mdc
```

---

**last updated**: January 2026
**Dart/Flutter version**: Dart 3+, Flutter 3.19+
**Baseado em**: Effective Dart 2026, Flutter AI Rules, Clean Architecture, SOLID Principles

