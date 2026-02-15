---
paths:
  - "lib/**/*.dart"
---


# Princípios SOLID

## Single Responsibility Principle (SRP)

- Each class must have a single responsibility
- A class must have only one reason to change
- Separe features distintas em classes diferentes
- Avoid "God Class" classes that do everything

**Correct Example:**

```dart
class User {
  final String id;
  final String name;
  // Apenas responsável por representar um user
}

class UserValidator {
  bool validate(User user) {
    // Apenas responsável por validar user
  }
}

class UserRepository {
  Future<User> save(User user) {
    // Apenas responsável por persistência
  }
}
```

## Open/Closed Principle (OCP)

- Classes must be open for extension, but closed for modification
- Use interfaces and inheritance to extend behavior
- Evite modificar código existente, adicione novas implementações

**Correct Example:**

```dart
abstract class PaymentMethod {
  Future<void> pay(double amount);
}

class CreditCard implements PaymentMethod {
  @override
  Future<void> pay(double amount) { /* implementação */ }
}

class PayPal implements PaymentMethod {
  @override
  Future<void> pay(double amount) { /* implementação */ }
}
```

## Liskov Substitution Principle (LSP)

- Objects of a base class must be able to be replaced by objects of its derived classes
- Subtypes must be replaceable with their base types without breaking the program
- Mantenha contratos de comportamento consistentes

**Correct Example:**

```dart
import 'dart:developer' as developer;

abstract class Animal {
  void makeSound();
}

class Dog implements Animal {
  @override
  void makeSound() => developer.log('Woof!');
}

class Cat implements Animal {
  @override
  void makeSound() => developer.log('Meow!');
}

// Qualquer Animal pode ser usado
void makeAnimalSound(Animal animal) {
  animal.makeSound(); // Funciona com Dog, Cat ou qualquer subtipo
}
```

## Interface Segregation Principle (ISP)

- Many specific interfaces are better than one general interface
- Clients should not be forced to depend on interfaces they do not use
- Crie interfaces pequenas e focadas

**Correct Example:**

```dart
abstract class Readable {
  Future<String> read();
}

abstract class Writable {
  Future<void> write(String data);
}

// Classe pode implementar apenas o que precisa
class FileReader implements Readable {
  @override
  Future<String> read() { /* implementação */ }
}
```

## Dependency Inversion Principle (DIP)

- Dependa de abstrações, not de implementações concretas
- Classes de alto nível not devem depender de classes de baixo nível
- Use injeção de dependência via construtor
- Defina interfaces no domínio, implemente na infraestrutura

**Correct Example:**

```dart
// Domain - Interface (abstração)
abstract class IUserRepository {
  Future<User> getById(String id);
}

// Application - Depende da abstração
class UserService {
  final IUserRepository repository; // Interface, not implementação

  UserService(this.repository);

  Future<User> getUser(String id) {
    return repository.getById(id);
  }
}

// Infrastructure - Implementa a abstração
class UserRepository implements IUserRepository {
  @override
  Future<User> getById(String id) { /* implementação */ }
}
```



