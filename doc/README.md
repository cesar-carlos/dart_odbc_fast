# Documentacao do projeto

Este diretorio contem apenas os documentos canonicos para uso diario de contribuidores e mantenedores.

## Guia rapido

| Documento                                                      | Objetivo                                                                   |
| -------------------------------------------------------------- | -------------------------------------------------------------------------- |
| [BUILD.md](BUILD.md)                                           | Setup local, build Rust, geracao opcional de bindings e execucao de testes |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md)                       | Diagnostico e correcoes para erros frequentes de build, runtime e CI       |
| [RELEASE_AUTOMATION.md](RELEASE_AUTOMATION.md)                 | Processo de release com tags + GitHub Actions + publicacao no pub.dev      |
| [VERSIONING_STRATEGY.md](VERSIONING_STRATEGY.md)               | Politica oficial de versionamento e deprecation                            |
| [VERSIONING_QUICK_REFERENCE.md](VERSIONING_QUICK_REFERENCE.md) | Referencia curta para decidir bump de versao                               |
| [CHANGELOG_TEMPLATE.md](CHANGELOG_TEMPLATE.md)                 | Modelo padrao para atualizar `CHANGELOG.md`                                |
| [OBSERVABILITY.md](OBSERVABILITY.md)                           | Telemetria, metricas operacionais e fallback de exportacao                 |
| [FUTURE_IMPLEMENTATIONS.md](FUTURE_IMPLEMENTATIONS.md)         | Backlog tecnico consolidado e priorizado                                   |

## Documentacao gerada

- `doc/api/` contem artefatos gerados por `dart doc`.
- Nao editar manualmente arquivos dentro de `doc/api/`.

## Notas tecnicas

- `doc/notes/` guarda notas de apoio e investigacoes pontuais.
- Arquivos em `doc/notes/` nao substituem os documentos canonicos.

## Regras de manutencao

1. Evite criar documentos paralelos sobre o mesmo tema. Atualize o documento canonico.
2. Quando um documento ficar historico, remova-o do indice e delete o arquivo.
3. Sempre valide links internos apos alteracoes maiores.
4. Para mudancas de release/versionamento, mantenha `pubspec.yaml`, `CHANGELOG.md` e docs sincronizados.
