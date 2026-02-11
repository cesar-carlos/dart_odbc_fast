# Claude Rules - Guia de Uso

Este diretório contém as regras usadas pelo Claude Code para manter consistência e qualidade no projeto.

## Estrutura

```
.claude/rules/
├── README.md
├── rules_index.md
├── general_rules.md
├── clean_architecture.md
├── solid_principles.md
├── coding_style.md
├── null_safety.md
├── testing.md
├── flutter_widgets.md
├── ui_ux_design.md
├── rust_style.md
└── error_handling.md
```

## Padrão Claude

- Regras ficam em `.claude/rules/*.md`
- Escopo por arquivo via frontmatter `paths`
- Sem `paths`, a regra vale para o projeto inteiro

Exemplo:

```yaml
---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---
```

## Origem das regras

- Essas regras foram derivadas de `./.cursor/rules` e convertidas para o formato de escopo do Claude (`paths`).
- O conteúdo técnico (Clean Architecture, SOLID, style, null safety, testing, UI/UX, Rust native e tratamento de erros) foi mantido.

## Referências

- https://docs.anthropic.com/en/docs/claude-code/memory
- https://docs.anthropic.com/en/docs/claude-code/settings
- https://doc.rust-lang.org/style-guide/
- https://rust-lang.github.io/rustfmt/
- https://doc.rust-lang.org/clippy/
- https://dart.dev/language/error-handling
- https://doc.rust-lang.org/std/error/
