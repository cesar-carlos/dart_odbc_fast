---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---


# Regras Gerais do Projeto

## Princípios Fundamentais (Core Principles)

- ✅ **Write concise, technical Dart code with accurate examples**
- ✅ **Use functional and declarative programming patterns where appropriate**
- ✅ **Prefer composition over inheritance**
- ✅ **Use descriptive variable names with auxiliary verbs** (e.g., `isLoading`, `hasError`, `canProceed`)
- ✅ **Structure files logically: exported widget, subwidgets, helpers, static content, types**
- ✅ **Prefer English for code identifiers** (classes, methods, variables); keep user-facing strings localizable

```dart
// ✅ Good: functional/declarative patterns
List<User> activeUsers = users.where((u) => u.isActive).toList();

// ✅ Good: composition over inheritance
class UserProfilePage extends StatelessWidget {
  final User user;
  const UserProfilePage({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        UserHeader(user: user),
        UserStats(user: user),
        UserActions(user: user),
      ],
    );
  }
}

// ✅ Good: descriptive boolean names with auxiliary verbs
bool isLoading = false;
bool hasError = true;
bool canProceed = isValid && isAuthorized;

// ✅ Good: logical file structure
// 1. Exported widget
class UserListPage extends StatelessWidget { }

// 2. Subwidgets (private)
class _UserListItem extends StatelessWidget { }
class _UserAvatar extends StatelessWidget { }

// 3. Helpers
String _formatUserName(User user) { }

// 4. Static content
const _defaultAvatar = 'assets/default_avatar.png';

// 5. Types
enum _UserSortOption { name, email, date }
```

## Documentação e Comentários

### Documentação Automática

- ❌ **NÃO gerar documentação automaticamente** sem necessidade real
- ❌ **NÃO adicionar comentários** que só repetem o que o código já mostra
- ❌ **NÃO suprimir erros/diagnósticos** (`// ignore`, `ignore_for_file`, `#[allow]`) fora da allowlist em `error_handling.md`
- ✅ **Código deve ser autoexplicativo** com nomes claros e boa decomposição
- ✅ Para APIs públicas exportadas de biblioteca, prefira `///` curtos quando o comportamento não for óbvio
- ✅ Para código interno de feature, documente só quando houver decisão/limitação importante

### Quando Documentar

- ✅ Comente o **porquê** (trade-off, regra externa, workaround), não o **o quê**
- ✅ Documente contratos públicos e casos não triviais (erros, side effects, invariantes)
- ✅ Mantenha comentários sincronizados com o código
- ✅ Prefira remover comentário redundante e melhorar o nome/extração de função

### Exemplo de Comportamento

**❌ NÃO fazer:**

```dart
/// Service for managing user operations.
///
/// This service provides methods to create, update, and delete users.
class UserService {
  /// Creates a new user with the given [name] and [email].
  ///
  /// Returns the created [User] if successful, or throws an exception.
  Future<User> createUser({
    required String name,
    required String email,
  }) async {
    // Implementação
  }
}
```

**✅ Fazer (sem documentação automática):**

```dart
class UserService {
  Future<User> createUser({
    required String name,
    required String email,
  }) async {
    // Implementação
  }
}
```

**✅ Fazer apenas quando solicitado:**

```dart
/// Service for managing user operations.
///
/// This service provides methods to create, update, and delete users.
class UserService {
  // Documentação criada apenas porque foi explicitamente solicitada
}
```

## Arquivos de Documentação

### Não Criar Automaticamente

- ❌ **NÃO criar** `README.md` automaticamente
- ❌ **NÃO criar** arquivos `.md` de documentação
- ❌ **NÃO criar** arquivos de changelog ou release notes
- ❌ **NÃO criar** arquivos de exemplo ou guias
- ✅ **Apenas criar** quando explicitamente solicitado

### Comentários no Código

**✅ Bom: Comentários apenas quando necessário**

```dart
// ✅ Bom: explica por quê (decisão importante)
// Usar cache local para reduzir chamadas à API em 80%
final cachedUser = await localCache.getUser(id);

// ✅ Bom: explica decisão arquitetural
// Usar Result ao invés de Exception para manter compatibilidade com Domain Layer
return await repository.getById(id);
```

**❌ Evite: Comentários desnecessários**

```dart
// ❌ Evite: explica o que (código já faz isso)
// Obter usuário do cache
final user = await cache.getUser(id);

// ❌ Evite: comentário óbvio
// Incrementar contador
_counter++;
```

## Princípios de Código Limpo

### Código Autoexplicativo

- ✅ Use nomes descritivos e claros
- ✅ Nomenclatura deve deixar o código autoexplicativo
- ✅ Evite comentários que apenas repetem o código
- ✅ Prefira código claro sobre comentários

### Tooling e Logging

- ✅ Siga `coding_style.md` para rotina de **format/fix/analyze** e padrões de logging
- ✅ Evite `print`; prefira logging estruturado (`dart:developer` `log`)

### Evitar Números Mágicos

- ❌ **NÃO usar números mágicos** no código
- ✅ **SEMPRE usar constantes nomeadas** para valores literais
- ✅ Use constantes com nomes descritivos que expliquem o propósito do valor
- ✅ Agrupe constantes relacionadas em classes ou arquivos dedicados

**❌ Evite: Números mágicos**

```dart
if (retryCount > 3) {
  throw Exception('Max retries exceeded');
}

await Future.delayed(Duration(seconds: 30));

if (user.age < 18) {
  return false;
}
```

**✅ Prefira: Constantes nomeadas**

```dart
const maxRetries = 3;
const defaultTimeout = Duration(seconds: 30);
const minimumAge = 18;

if (retryCount > maxRetries) {
  throw Exception('Max retries exceeded');
}

await Future.delayed(defaultTimeout);

if (user.age < minimumAge) {
  return false;
}
```

**✅ Para constantes relacionadas, use classes:**

```dart
class Timeouts {
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration shortTimeout = Duration(seconds: 5);
  static const Duration longTimeout = Duration(minutes: 5);
}

class Limits {
  static const int maxRetries = 3;
  static const int maxFileSize = 1024 * 1024;
  static const int minPasswordLength = 8;
}
```

### Exemplo

**❌ Evite:**

```dart
// Criar usuário
void createUser(String name) {
  // Validar nome
  if (name.isEmpty) {
    // Lançar erro
    throw Exception('Name cannot be empty');
  }
  // Salvar usuário
  _saveUser(name);
}
```

**✅ Prefira:**

```dart
void createUser(String name) {
  if (name.isEmpty) {
    throw Exception('Name cannot be empty');
  }
  _saveUser(name);
}
```

## Criação de Componentes

### Priorizar Componentes Reutilizáveis

- ✅ **PRIORIZE criação de componentes** para padronização de layout
- ✅ **EVITE duplicação de código** - extraia padrões repetidos em componentes
- ✅ Componentes devem ser reutilizáveis em diferentes contextos
- ✅ Use composição de componentes ao invés de copiar/colar código

**❌ Evite: Código duplicado**

```dart
// ❌ Evite: mesmo padrão repetido em múltiplos lugares
// Page 1
Container(
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.1),
        blurRadius: 10,
      ),
    ],
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Title 1', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Content 1'),
    ],
  ),
)

// Page 2 - mesmo código duplicado
Container(
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.1),
        blurRadius: 10,
      ),
    ],
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Title 2', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('Content 2'),
    ],
  ),
)
```

**✅ Prefira: Componente reutilizável**

```dart
// ✅ Bom: componente reutilizável
class CardContainer extends StatelessWidget {
  final String title;
  final String content;

  const CardContainer({
    super.key,
    required this.title,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(content),
        ],
      ),
    );
  }
}

// Uso em Page 1
const CardContainer(title: 'Title 1', content: 'Content 1')

// Uso em Page 2
const CardContainer(title: 'Title 2', content: 'Content 2')
```

### Quando Criar Componentes

Crie um componente quando:
- ✅ O mesmo padrão de UI aparece **2 ou mais vezes**
- ✅ O componente tem **responsabilidade única e clara**
- ✅ O componente pode ser **reutilizado em diferentes contextos**
- ✅ O componente ajuda a **manter consistência visual**

### Exemplo: Botão Personalizado

```dart
// ✅ Bom: componente de botão padronizado
class AppButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;

  const AppButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: isLoading
          ? const CircularProgressIndicator()
          : Text(text),
    );
  }
}
```

## Checklist de Regras Gerais

### Princípios Fundamentais
- [ ] Escrever código conciso e técnico
- [ ] Usar padrões funcionais e declarativos quando apropriado
- [ ] Preferir composição sobre herança
- [ ] Usar nomes descritivos com verbos auxiliares (isLoading, hasError, canProceed)
- [ ] Estruturar arquivos logicamente: exported widget, subwidgets, helpers, static content, types

### Documentação e Comentários
- [ ] NÃO gerar documentação automática sem necessidade
- [ ] NÃO criar arquivos `.md` sem solicitação explícita
- [ ] NÃO adicionar comentários redundantes
- [ ] Código deve ser autoexplicativo
- [ ] Documentar API pública exportada quando necessário
- [ ] Comentários apenas para explicar "por quê", não "o quê"
- [ ] Usar nomenclatura clara ao invés de comentários

### Código Limpo
- [ ] Evitar números mágicos - usar constantes nomeadas
- [ ] Manter código limpo e manutenível
- [ ] **PRIORIZAR criação de componentes** para padronização
- [ ] **EVITAR duplicação de código** - extrair padrões em componentes


