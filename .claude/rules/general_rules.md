---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---


# General Project Rules

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

## documentation e Comentários

### documentation Automática

- ❌ **not gerar documentation automaticamente** sem necessidade real
- ❌ **not add comments** that only repeat what the code already shows
- ❌ **not suprimir erros/diagnósticos** (`// ignore`, `ignore_for_file`, `#[allow]`) fora da allowlist em `error_handling.md`
- ✅ **Code must be self-explanatory** with clear names and good decomposition
- ✅ For library-exported public APIs, prefer short `///` when the behavior is not obvious
- ✅ For internal feature code, document only when there is an important decision/limitation

### Quando Documentar

- ✅ Comment on the **why** (trade-off, external rule, workaround), not the **what**
- ✅ Documente contratos públicos e casos not triviais (erros, side effects, invariantes)
- ✅ Keep comments synced with code
- ✅ Prefer remove redundant comment and improve function name/extraction

### Example of Behavior

**❌ not fazer:**

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

**✅ Fazer (sem documentation automática):**

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
  // documentation criada apenas porque foi explicitamente solicitada
}
```

## Arquivos de documentation

### not create Automaticamente

- ❌ **not create** `README.md` automaticamente
- ❌ **not create** arquivos `.md` de documentation
- ❌ **not create** arquivos de changelog ou release notes
- ❌ **not create** example files or guides
- ✅ **Apenas create** quando explicitamente solicitado

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
// Obter user do cache
final user = await cache.getUser(id);

// ❌ Evite: comentário óbvio
// Incrementar contador
_counter++;
```

## Princípios de Código Limpo

### Código Autoexplicativo

- ✅ Use nomes descritivos e claros
- ✅ Nomenclature must make the code self-explanatory
- ✅ Avoid comments that just repeat the code
- ✅ Prefira código claro sobre comentários

### Tooling e Logging

- ✅ Follow `coding_style.md` for **format/fix/analyze** routine and logging patterns
- ✅ Evite `print`; prefira logging estruturado (`dart:developer` `log`)

### Evitar Números Mágicos

- ❌ **not usar números mágicos** no código
- ✅ **ALWAYS use named constants** for literal values
- ✅ Use constants with descriptive names that explain the purpose of the value
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

**✅ For related constants, use classes:**

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

### Example

**❌ Evite:**

```dart
// create user
void createUser(String name) {
  // Validar nome
  if (name.isEmpty) {
    // Lançar erro
    throw Exception('Name cannot be empty');
  }
  // Salvar user
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

- ✅ **PRIORIZE component creation** for layout standardization
- ✅ **EVITE duplicação de código** - extraia padrões repetidos em componentes
- ✅ Componentes devem ser reutilizáveis em diferentes contextos
- ✅ Use component composition instead of copying/pasting code

**❌ Evite: Código duplicado**

```dart
// ❌ Evite: mesmo default repetido em múltiplos lugares
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

### Quando create Componentes

Create a component when:
- ✅ The same UI default appears **2 or more times**
- ✅ The component has **single and clear responsibility**
- ✅ The component can be **reused in different contexts**
- ✅ The component helps **maintain visual consistency**

### Example: Custom Button

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
- [ ] Use descriptive names with auxiliary verbs (isLoading, hasError, canProceed)
- [ ] Estruturar arquivos logicamente: exported widget, subwidgets, helpers, static content, types

### documentation e Comentários
- [ ] not gerar documentation automática sem necessidade
- [ ] not create arquivos `.md` sem solicitação explícita
- [ ] not add redundant comments
- [ ] Código must ser autoexplicativo
- [ ] Documentar API pública exportada quando necessário
- [ ] Comments only to explain "why", not "what"
- [ ] Use clear nomenclature instead of comments

### Código Limpo
- [ ] Evitar números mágicos - usar constantes nomeadas
- [ ] Manter código limpo e manutenível
- [ ] **PRIORIZE creation of components** for standardization
- [ ] **EVITAR duplicação de código** - extrair padrões em componentes



