---
paths:
  - "test/**/*.dart"
---


# Padrões de Testes

## Estrutura de Testes

### Organização

Tests must follow the same folder structure as the code:

```
lib/
├── domain/
│   ├── entities/
│   ├── use_cases/
│   └── repositories/

test/
├── domain/
│   ├── entities/
│   ├── use_cases/
│   └── repositories/
```

## Testes Unitários

### Use Cases

```dart
// test/domain/use_cases/get_user_by_id_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:result_dart/result_dart.dart';
import 'package:domain/domain.dart';
import 'package:mocktail/mocktail.dart';

class MockUserRepository extends Mock implements IUserRepository {}

void main() {
  late GetUserById useCase;
  late MockUserRepository mockRepository;

  setUp(() {
    mockRepository = MockUserRepository();
    useCase = GetUserById(mockRepository);
  });

  group('GetUserById', () {
    test('should return User when repository succeeds', () async {
      // Arrange
      final user = User(
        id: '123',
        name: 'John Doe',
        email: Email('john@example.com'),
        createdAt: DateTime.now(),
      );

      when(() => mockRepository.getById('123'))
          .thenAnswer((_) async => Success(user));

      // Act
      final result = await useCase('123');

      // Assert
      expect(result.isSuccess(), isTrue);
      result.fold(
        (success) => expect(success, equals(user)),
        (failure) => fail('Should not return failure'),
      );

      verify(() => mockRepository.getById('123')).called(1);
    });

    test('should return Failure when repository fails', () async {
      // Arrange
      when(() => mockRepository.getById('123'))
          .thenAnswer((_) async => Failure(ServerFailure('Error')));

      // Act
      final result = await useCase('123');

      // Assert
      expect(result.isFailure(), isTrue);
      result.fold(
        (success) => fail('Should not return user'),
        (failure) => expect(failure, isA<ServerFailure>()),
      );
    });

    test('should return ValidationFailure when id is empty', () async {
      // Act
      final result = await useCase('');

      // Assert
      expect(result.isFailure(), isTrue);
      result.fold(
        (success) => fail('Should not return user'),
        (failure) => expect(failure, isA<ValidationFailure>()),
      );

      verifyNever(() => mockRepository.getById(any()));
    });
  });
}
```

### Entities

```dart
// test/domain/entities/user_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:domain/domain.dart';

void main() {
  group('User', () {
    test('should be equal when ids are the same', () {
      // Arrange
      final user1 = User(
        id: '123',
        name: 'John',
        email: Email('john@example.com'),
        createdAt: DateTime.now(),
      );

      final user2 = User(
        id: '123',
        name: 'Jane',
        email: Email('jane@example.com'),
        createdAt: DateTime.now(),
      );

      // Assert
      expect(user1, equals(user2));
      expect(user1.hashCode, equals(user2.hashCode));
    });

    test('should not be equal when ids are different', () {
      // Arrange
      final user1 = User(
        id: '123',
        name: 'John',
        email: Email('john@example.com'),
        createdAt: DateTime.now(),
      );

      final user2 = User(
        id: '456',
        name: 'John',
        email: Email('john@example.com'),
        createdAt: DateTime.now(),
      );

      // Assert
      expect(user1, isNot(equals(user2)));
    });

    test('isActive should return true for recent users', () {
      // Arrange
      final user = User(
        id: '123',
        name: 'John',
        email: Email('john@example.com'),
        createdAt: DateTime.now().subtract(Duration(days: 10)),
      );

      // Assert
      expect(user.isActive(), isTrue);
    });
  });
}
```

### Value Objects

```dart
// test/domain/value_objects/email_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:domain/domain.dart';

void main() {
  group('Email', () {
    test('should create valid email', () {
      // Arrange & Act
      final email = Email('test@example.com');

      // Assert
      expect(email.value, equals('test@example.com'));
    });

    test('should throw exception for invalid email', () {
      // Assert
      expect(
        () => Email('invalid-email'),
        throwsA(isA<InvalidEmailException>()),
      );
    });

    test('should be equal when values are the same', () {
      // Arrange
      final email1 = Email('test@example.com');
      final email2 = Email('test@example.com');

      // Assert
      expect(email1, equals(email2));
      expect(email1.hashCode, equals(email2.hashCode));
    });
  });
}
```

## Testes de Widgets

```dart
// test/presentation/pages/user_page_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:presentation/presentation.dart';

void main() {
  group('UserPage', () {
    testWidgets('should display user name', (WidgetTester tester) async {
      // Arrange
      final user = User(/* ... */);

      // Act
      await tester.pumpWidget(
        MaterialApp(
          home: UserPage(user: user),
        ),
      );

      // Assert
      expect(find.text(user.name), findsOneWidget);
    });
  });
}
```

## Boas Práticas

### AAA Pattern (Arrange, Act, Assert)

```dart
test('should do something', () {
  // Arrange - Preparar dados e dependências
  final user = User(/* ... */);
  final repository = MockRepository();

  // Act - Executar ação
  final result = useCase(user);

  // Assert - Verificar resultado
  expect(result, isNotNull);
});
```

### Nomenclatura de Testes

- Describe expected behavior
- Use formato: `should [verbo] when [condição]`
- Examples:
  - `should return User when repository succeeds`
  - `should return Failure when id is empty`
  - `should throw exception when email is invalid`

### Isolamento

- Cada teste must ser independente
- Use `setUp()` and `tearDown()` for preparation and cleanup
- not compartilhe estado entre testes

### Mocking

- Use `mocktail` or `mockito` to create mocks
- Mock apenas dependências externas
- not mock entidades ou value objects do domínio

### Assertions (package:checks)

- ✅ **Use `package:checks`** for more expressive and readable assertions
- ✅ `package:checks` provides a more fluid syntax than the default matchers
- ✅ Preferable to using `expect` with traditional matchers

```dart
// ✅ Good: package:checks syntax (mais expressivo)
import 'package:checks/checks.dart';

test('should return user with valid data', () {
  final user = getUserById('123');

  // Sintaxe fluida e encadeada
  check(user)
    .id.equals('123')
    .name.isNotNull()
    .email.contains('@')
    .age.isGreaterThanOrEqual(18);
});

// ✅ Good: verificações múltiplas em uma única expressão
check(result)
  .isA<User>()
  .equals((name: 'John', email: 'john@example.com'));

// ✅ Good: coleções
check(users)
  .length.isGreaterThan(0)
  .any((u) => u.isActive);

// ❌ Avoid: matchers tradicionais (menos legíveis)
import 'package:flutter_test/flutter_test.dart';

expect(user.id, equals('123'));
expect(user.name, isNotNull);
expect(user.email, contains('@'));
```

### Cobertura

- Busque alta cobertura de código crítico (Domain Layer)
- Teste casos de success e failure
- Teste casos extremos (valores vazios, null, etc.)



