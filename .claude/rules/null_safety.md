---
paths:
  - "lib/**/*.dart"
---


# Null Safety - Boas Práticas

## Princípios Fundamentais

### Null Safety no Dart
- ✅ Dart 2.12+ tem null safety habilitado por default
- ✅ Variáveis not são nullable por default
- ✅ Use `?` only when necessary
- ✅ Evite `null` quando possível

## Declaração de Tipos

### Non-nullable por default
- ✅ Variáveis são non-nullable por default
- ✅ Use explicit types for clarity

```dart
// ✅ Bom: non-nullable por default
String userName = 'John';
int age = 25;
bool isActive = true;

// ❌ not funciona: not pode ser null
String userName = null; // Error: A value of type 'Null' can't be assigned
```

### Nullable Types
- ✅ Use `?` only when really necessary
- ✅ Document why a variable can be null

```dart
// ✅ Bom: nullable quando necessário
String? optionalUserName;
int? optionalAge;

// ✅ Bom: nullable com documentation
/// User name. Can be null if user hasn't set a name yet.
String? userName;

// ❌ Evite: nullable desnecessário
String? userName = 'John'; // not precisa ser nullable se sempre terá valor
```

## Inicialização

### Variáveis Locais
- ✅ Inicialize variáveis imediatamente ou use `late`
- ✅ Use `final` when the value does not change

```dart
// ✅ Bom: inicialização imediata
String userName = 'John';

// ✅ Bom: late para inicialização tardia
late String userName;
void init() {
  userName = 'John';
}

// ❌ Erro: variable not inicializada
String userName; // Error: 'userName' must be initialized
```

### Campos de Classe
- ✅ Inicialize campos no construtor ou use `late`
- ✅ Use `late` for late startup

```dart
// ✅ Bom: inicialização no construtor
class User {
  final String name;
  final String? email;
  
  User({required this.name, this.email});
}

// ✅ Bom: late para inicialização tardia
class User {
  late String name;
  
  void initialize(String userName) {
    name = userName;
  }
}

// ✅ Bom: nullable para valores opcionais
class User {
  final String name;
  final String? nickname; // Pode ser null
}
```

## Null Checks

### Null-aware Operators
- ✅ Use `?.` for secure calls
- ✅ Use `??` for default values
- ✅ Use `??=` for conditional assignment

```dart
// ✅ Bom: null-aware operator
String? userName;
int length = userName?.length ?? 0; // returns 0 se userName é null

// ✅ Bom: null-coalescing operator
String displayName = userName ?? 'Anonymous';

// ✅ Bom: null-aware assignment
String? userName;
userName ??= 'Default'; // Atribui apenas se for null
```

### Null Assertion
- ✅ Use `!` apenas quando absolutamente seguro
- ✅ Evite `!` quando possível (use null checks)
- ✅ Document why it is safe to use `!`

```dart
// ✅ Bom: null check antes de usar
String? userName;
if (userName != null) {
  int length = userName.length; // Safe: já verificamos
}

// ⚠️ Use com cuidado: null assertion
String? userName;
int length = userName!.length; // Pode lançar exceção se null

// ✅ Melhor: usar null-aware operator
int length = userName?.length ?? 0;

// ✅ Bom: quando garantido que not é null
String getUserName() {
  final user = _currentUser!; // Garantido que not é null neste ponto
  return user.name;
}
```

## Collections Nullable

### List
- ✅ Use `List<T?>` for lists that can contain null
- ✅ Prefira `List<T>` quando possível

```dart
// ✅ Bom: lista not-nullable
List<String> names = ['John', 'Jane'];

// ✅ Bom: lista nullable quando necessário
List<String?> names = ['John', null, 'Jane'];

// ✅ Bom: lista nullable de non-nullable
List<String>? names; // Lista pode ser null, mas elementos not são null
```

### Map
- ✅ Use `Map<K, V?>` when values ​​can be null
- ✅ Treat nulls when accessing maps

```dart
// ✅ Bom: valores nullable
Map<String, int?> scores = {
  'John': 100,
  'Jane': null,
};

// ✅ Bom: acesso seguro
int? score = scores['John']; // Pode ser null
int safeScore = scores['John'] ?? 0; // Valor default
```

## Funções e Métodos

### parameters Nullable
- ✅ Use `required` for mandatory parameters
- ✅ Use `?` for optional parameters that can be null
- ✅ Use valores default quando possível

```dart
// ✅ Bom: parameter obrigatório
void createUser(String name) { }

// ✅ Bom: parameter opcional nullable
void createUser(String name, {String? email}) { }

// ✅ Bom: valor default (preferível sobre nullable)
void createUser(String name, {String email = ''}) { }

// ✅ Bom: required para nullable quando necessário
void createUser({
  required String name,
  String? email, // Opcional e pode ser null
}) { }
```

### Retorno Nullable
- ✅ Return `T?` when the result may be null
- ✅ Documente quando null pode ser retornado

```dart
// ✅ Bom: retorno nullable quando necessário
String? findUser(String id) {
  // returns null se not encontrar
  return _users[id];
}

// ✅ Bom: retorno non-nullable quando sempre tem valor
String getUserName() {
  return _currentUser.name; // Garantido que not é null
}

// ✅ Bom: documentation
/// Finds a user by ID. Returns null if user not found.
User? findUser(String id) {
  return _users[id];
}
```

## Null Safety with Generics

### Generic Types
- ✅ Use `T?` for generic nullable types
- ✅ Use `T` for non-nullable generic types

```dart
// ✅ Bom: generic non-nullable
class Repository<T> {
  Future<T> findById(String id) async { /* ... */ }
}

// ✅ Bom: generic nullable
class Repository<T> {
  Future<T?> findById(String id) async { /* ... */ }
}

// ✅ Bom: uso
final userRepo = Repository<User>();
final user = await userRepo.findById('123'); // User?
```

## Null Safety em APIs

### APIs Externas
- ✅ Trate nulls de APIs externas
- ✅ Validate data before use
- ✅ Use mappers to convert nulls

```dart
// ✅ Bom: tratamento de nulls de API
class UserModel {
  final String? name;
  final String? email;
  
  UserModel({this.name, this.email});
  
  User toEntity() {
    return User(
      name: name ?? 'Unknown',
      email: email ?? '',
    );
  }
}
```

### JSON Parsing
- ✅ Treat nulls when parsing JSON
- ✅ Use valores default quando necessário

```dart
// ✅ Bom: parse seguro de JSON
UserModel.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String?,
      email = json['email'] as String?;

// ✅ Bom: com valores default
UserModel.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String? ?? 'Unknown',
      email = json['email'] as String? ?? '';
```

## Boas Práticas

### Evitar Null
- ✅ Prefira valores default sobre null
- ✅ Use enums for states instead of null
- ✅ Use Optional types quando apropriado

```dart
// ✅ Bom: valor default
String getUserName() => _userName ?? 'Anonymous';

// ✅ Bom: enum ao invés de null
enum UserStatus { active, inactive, pending }

// ✅ Bom: Optional type
class Optional<T> {
  final T? _value;
  Optional(this._value);
  bool get isPresent => _value != null;
  T get value => _value!;
}
```

### Validação
- ✅ Valide nulls antes de usar
- ✅ Use asserts em desenvolvimento
- ✅ Trate nulls graciosamente

```dart
// ✅ Bom: validação
String getUserName() {
  if (_userName == null) {
    throw StateError('User name not set');
  }
  return _userName!;
}

// ✅ Bom: validação com assert
String getUserName() {
  assert(_userName != null, 'User name must be set');
  return _userName!;
}

// ✅ Bom: tratamento gracioso
String getUserName() => _userName ?? 'Anonymous';
```

### documentation
- ✅ Documente quando nulls são esperados
- ✅ Explain why a variable is nullable
- ✅ Documente quando null pode ser retornado

```dart
/// User service for managing user operations.
class UserService {
  /// Current user. Can be null if no user is logged in.
  User? _currentUser;
  
  /// Gets the current user. Returns null if no user is logged in.
  User? getCurrentUser() {
    return _currentUser;
  }
}
```

## Checklist

- [ ] Variáveis são non-nullable por default
- [ ] Nullable (`?`) is only used when necessary
- [ ] Variáveis são inicializadas ou marcadas como `late`
- [ ] Null checks são feitos antes de usar valores nullable
- [ ] Null-aware operators (`?.`, `??`) are used when appropriate
- [ ] `!` é usado apenas quando absolutamente seguro
- [ ] Functions return `T?` when null is possible
- [ ] parameters nullable são documentados
- [ ] APIs externas tratam nulls adequadamente



