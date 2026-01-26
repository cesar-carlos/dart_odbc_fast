# API Governance

## Versionamento Semântico

### API Version (Semantic Versioning)

Formato: `MAJOR.MINOR.PATCH`

- **MAJOR**: Mudanças incompatíveis na API pública
- **MINOR**: Novas funcionalidades compatíveis com versões anteriores
- **PATCH**: Correções de bugs compatíveis

**Versão Atual**: 0.1.0

### Protocol Version

Formato: `MAJOR.MINOR`

- **MAJOR**: Mudanças incompatíveis no protocolo binário
- **MINOR**: Extensões compatíveis do protocolo

**Versões Suportadas**:
- v1.0: RowBuffer row-based (compatível)
- v2.0: RowBuffer columnar (atual)

### ABI Version

Formato: `MAJOR.MINOR`

- **MAJOR**: Mudanças incompatíveis na ABI FFI
- **MINOR**: Extensões compatíveis da ABI

**Versão Atual**: 1.0

## Política de Compatibilidade

### Backward Compatibility

- **MAJOR = 0**: API em desenvolvimento, mudanças podem ser incompatíveis
- **MAJOR >= 1**: Garantia de compatibilidade para MINOR e PATCH
- Protocol v1 e v2 são suportados simultaneamente
- ABI mantém compatibilidade dentro da mesma versão MAJOR

### Deprecation Policy

- Funcionalidades deprecadas são mantidas por pelo menos 2 versões MINOR
- Avisos de deprecation são documentados e logados
- Migration guides são fornecidos

## LTS (Long Term Support)

### Estratégia LTS

- Versões LTS são marcadas como `MAJOR.MINOR.0-LTS`
- Suporte por pelo menos 12 meses
- Apenas correções de segurança e bugs críticos
- Documentação de migration para novas versões

### Release Cycle

- **Feature releases**: A cada 3-6 meses (MINOR)
- **Patch releases**: Conforme necessário (PATCH)
- **LTS releases**: A cada 12-18 meses (MAJOR)

## Breaking Changes

### Quando Incrementar MAJOR

- Mudanças na API pública Dart
- Mudanças incompatíveis no protocolo binário
- Mudanças incompatíveis na ABI FFI
- Remoção de funcionalidades públicas

### Processo de Breaking Changes

1. Deprecation notice na versão anterior
2. Migration guide disponível
3. Período de transição (2 versões MINOR)
4. Breaking change na próxima versão MAJOR

## Versionamento de Dependências

### Rust Dependencies

- Versões fixas para estabilidade
- Atualizações testadas antes de release
- Security patches aplicados imediatamente

### Dart Dependencies

- Compatibilidade com SDK >=3.0.0
- Dependências mínimas necessárias
- Versões testadas e validadas

## Checklist de Release

- [ ] Todos os testes passam
- [ ] Benchmarks de performance atendidos
- [ ] Security audit completo
- [ ] Documentação atualizada
- [ ] Changelog criado
- [ ] Migration guide (se necessário)
- [ ] Release notes preparadas
- [ ] CI/CD validado em todas as plataformas
- [ ] Version numbers atualizados
- [ ] Tags Git criadas
