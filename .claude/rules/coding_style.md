---
paths:
  - "lib/**/*.dart"
  - "test/**/*.dart"
---


# Dart Style Guide - Effective Dart (2026)

**Based on**: [Effective Dart](https://dart.dev/effective-dart) and [Flutter AI Rules](https://docs.flutter.dev/ai/ai-rules)

## Language & Syntax

### Type Declarations
- ✅ **Always declare types** for variables, parameters, and return values
- ✅ Use explicit types for public APIs
- ✅ Avoid `var` when type is clear and improves readability
- ✅ Avoid `dynamic` for application code; prefer concrete types (e.g., `Map<String, Object?>`)

```dart
// ✅ Good: explicit types
String userName = 'John';
int calculateAge(DateTime birthDate) { }
List<User> getActiveUsers() { }

// ❌ Avoid: ambiguous types
var userName = 'John';
var age = calculateAge(birthDate);
```

### Readability inside functions

- ✅ Use blank lines sparingly to separate phases (validation → work → return)
- ✅ Prefer early returns to reduce nesting

### Const Constructors
- ✅ **Use const constructors** for immutable widgets to optimize rebuilds
- ✅ Use `const` for values known at compile time
- ✅ Reduces unnecessary rebuilds and improves performance

```dart
// ✅ Good: const constructors
class MyWidget extends StatelessWidget {
  const MyWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Text('Hello'),
        Text('World'),
      ],
    );
  }
}

// ❌ Avoid: missing const
class MyWidget extends StatelessWidget {
  MyWidget({super.key});  // Should be const

  @override
  Widget build(BuildContext context) {
    return Column(  // Should be const
      children: [
        Text('Hello'),  // Should be const
      ],
    );
  }
}
```

### Arrow Syntax
- ✅ **Leverage arrow syntax** for simple functions and methods
- ✅ Use arrow syntax for one-line functions
- ✅ Improves readability for simple operations

```dart
// ✅ Good: arrow syntax for simple functions
String getUserName() => 'John';
bool isValid() => _user != null;
int get userAge => _user.age;

// ✅ Good: full function body for complex logic
String getFormattedUserName() {
  if (_user == null) return 'Guest';
  return '${_user.firstName} ${_user.lastName}'.trim();
}
```

### Expression Bodies
- ✅ **Prefer expression bodies** for one-line getters and setters
- ✅ Use `=>` for single-expression getters
- ✅ Improves code conciseness

```dart
// ✅ Good: expression bodies for getters
bool get isValid => _id != null && _id.isNotEmpty;
bool get isLoading => _status == Status.loading;
int get itemCount => _items.length;

// ❌ Avoid: unnecessary block for simple getter
bool get isValid {
  return _id != null && _id.isNotEmpty;
}
```

### Trailing Commas
- ✅ **Use trailing commas** for better formatting and diffs
- ✅ Add trailing comma to multi-line function calls, lists, and parameters
- ✅ Helps with git diffs and code formatting

```dart
// ✅ Good: trailing commas
Column(
  children: [
    Text('Title'),
    Text('Subtitle'),
    ElevatedButton(
      onPressed: () {},
      child: Text('Click'),
    ),
  ],
)

void createUser({
  required String name,
  required String email,
  int age = 0,
}) { }

// ❌ Avoid: missing trailing commas
Column(
  children: [
    Text('Title'),
    Text('Subtitle')
  ]
)
```

### Line Length
- ✅ **Keep lines under 80 characters** where possible
- ✅ Break long lines for better readability
- ✅ Use line breaks logically

```dart
// ✅ Good: lines under 80 characters
final String userName = 'John Doe';
final bool isActive = user.status == UserStatus.active;

// ✅ Good: breaking long lines
final String message = 'Hello ${user.firstName} ${user.lastName}, '
    'welcome to our application!';

return ElevatedButton(
  onPressed: _handleButtonClick,
  child: const Text('Submit'),
);

// ❌ Avoid: excessively long lines
final String message = 'Hello ${user.firstName} ${user.lastName}, welcome to our application! Your account has been created successfully.';
```

## Naming Conventions

### Types and Extensions

Use **UpperCamelCase** for class names, enums, typedefs, type parameters, and extension names.

```dart
class UserService { }
enum UserRole { }
typedef UserCallback = void Function(User);
extension StringExtensions on String { }
```

### Libraries, Packages, Directories, and Files

Use **lowercase_with_underscores**.

```dart
// File: user_service.dart
// Folder: user_services/
// Package name: my_app_package
```

### Other Identifiers

Use **lowerCamelCase** for variables, methods, named parameters, and type parameters.

```dart
String userName = 'John';
void getUserData() { }
void createUser(String userName) { }
class GenericRepository<T> { }
```

### Function Names

- ✅ **Start function names with verbs** to indicate actions
- ✅ Use descriptive names that clearly indicate what the function does
- ✅ Common prefixes: `get`, `set`, `create`, `update`, `delete`, `is`, `has`, `can`

```dart
// ✅ Good: function names start with verbs
String getData() { }
void updateUser(User user) { }
bool isValidEmail(String email) { }
bool canSubmitForm() { }
void deleteItem(String id) { }

// ❌ Avoid: function names without verbs
String data() { }          // Should be getData
void user(User user) { }   // Should be updateUser
bool email(String email) { } // Should be isValidEmail
```

### Boolean Variables

- ✅ **Use descriptive boolean names with auxiliary verbs**
- ✅ Use prefixes like `is`, `has`, `can`, `should`, `will`, `needs`
- ✅ Avoid negative boolean names (double negatives are confusing)

```dart
// ✅ Good: boolean names with auxiliary verbs
bool isLoading = false;
bool hasError = true;
bool canProceed = isValid && isAuthorized;
bool shouldRefresh = data.isStale;
bool willDelete = false;
bool needsUpdate = true;

// ❌ Avoid: unclear boolean names
bool loading = false;          // Should be isLoading
bool error = true;             // Should be hasError
bool proceed = false;          // Should be canProceed
bool notValid = false;         // Avoid negatives (use isValid)
```

### Constants and Enum Values

Use **lowerCamelCase** for constants and enum values (prefer `const` over `static final`).

Exception: Maintain **SCREAMING_CAPS** only when interoperating with existing code or tools (Java interop, protobuf).

```dart
const maxRetries = 3;
const defaultTimeout = Duration(seconds: 30);

// Class constants
static const String apiUrl = 'https://api.example.com';

// Enums
enum UserStatus {
  active,
  inactive,
  pending,
}
```

### Private Members

Use **underscore prefix** for private members.

```dart
final String _privateField;
void _privateMethod() { }
```

### Avoid Prefix Notation

Don't use Hungarian notation (prefixing type information to variable names).

```dart
// ❌ Avoid
String sName;
int nAge;

// ✅ Prefer
String userName;
int age;
```

### Unused Parameters

Use `_`, `__`, `___`, etc. for unused callback parameters.

```dart
// ✅ Good: unused parameter marked with _
Future<void> processItems(List<Item> items) async {
  for (final _ in items) {
    // Process item without needing to name it
  }
}
```

## Import Organization

### Import Order

1. `dart:` imports
2. `package:` imports
3. Relative imports

Within each section, sort items alphabetically.

### Import Order Example

```dart
// 1. Dart SDK
import 'dart:async';
import 'dart:convert';

// 2. External packages
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:result_dart/result_dart.dart';

// 3. Relative imports
import '../models/user.dart';
import 'user_service.dart';
```

### Export Directives

Place `export` directives after all imports.

```dart
import 'package:my_app/services/user_service.dart';

export 'models/user.dart';
export 'user_service.dart';
```

### Avoid `library` Directive

The `library` directive is a legacy feature and should not be used.

```dart
// ❌ Avoid
library user_repository;

// ✅ Prefer (no library directive)
```

## Const and Final

### Use Const

- ✅ Use `const` for values known at compile time
- ✅ Use `const` constructors when possible for better performance
- ✅ Use `const` in immutable widgets

```dart
// ✅ Good: const for fixed values
const int maxRetries = 3;
const Duration timeout = Duration(seconds: 30);

// ✅ Good: const constructor
const Text('Hello');

// ✅ Good: const widget
class MyWidget extends StatelessWidget {
  const MyWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text('Hello');
  }
}
```

### Use Final

- ✅ Use `final` for variables that won't be reassigned
- ✅ Prefer `final` over `var` when the value doesn't change

```dart
// ✅ Good: final for immutable values
final String userName = 'John';
final List<int> numbers = [1, 2, 3];

// ❌ Avoid: var when final is sufficient
var userName = 'John'; // Should be final
```

## Strings

### String Interpolation

Use string interpolation instead of concatenation.

```dart
// ✅ Good
String message = 'Hello, $userName!';
String fullName = '${user.firstName} ${user.lastName}';

// ❌ Avoid
String message = 'Hello, ' + userName + '!';
```

### Multiline Strings

Use triple quotes for multiline strings.

```dart
String longText = '''
  This is a
  multiline string
''';
```

## Collections

### Lists

- ✅ Use list literals when possible
- ✅ Prefer `List<T>` over untyped `List`

```dart
// ✅ Good: explicit type
List<String> names = ['John', 'Jane'];

// ✅ Good: const list
const List<String> defaultNames = ['John', 'Jane'];

// ❌ Avoid: untyped
List names = ['John', 'Jane'];
```

### Maps

- ✅ Use map literals when possible
- ✅ Prefer `Map<String, T>` over untyped `Map`

```dart
// ✅ Good: explicit type
Map<String, int> scores = {'John': 100, 'Jane': 95};

// ❌ Avoid: untyped
Map scores = {'John': 100, 'Jane': 95};
```

### Sets

Use set literals when possible.

```dart
Set<String> uniqueNames = {'John', 'Jane', 'John'}; // {'John', 'Jane'}
```

## Functions and Methods

### Function Length
- ✅ Functions should be **short and with single purpose** (strive for **< 20 lines**)
- ✅ Extract complex logic into separate, well-named functions
- ✅ Each function should do one thing well

```dart
// ✅ Good: short, focused function (< 20 lines)
String formatUserName(User user) {
  if (user.firstName.isEmpty && user.lastName.isEmpty) {
    return 'Anonymous';
  }
  return '${user.firstName} ${user.lastName}'.trim();
}

// ❌ Avoid: long function doing multiple things (> 20 lines)
String formatAndValidateAndSaveUser(User user) {
  // 50+ lines of logic...
}
```

### Positional vs Named Parameters

- ✅ Use positional parameters for required and clear semantics
- ✅ Use named parameters for optional and better readability
- ✅ Use optional positional parameters rarely

```dart
// ✅ Good: required positional parameters
void createUser(String name, String email) { }

// ✅ Good: optional named parameters
void createUser({
  required String name,
  String? email,
  int age = 0,
}) { }

// ✅ Good: optional positional parameters (rarely)
void createUser(String name, [String? email]) { }
```

### Arrow Functions

Use arrow functions for simple one-line functions.

```dart
// ✅ Good: arrow function
String getUserName() => 'John';

// ✅ Good: full function for complex logic
String getUserName() {
  // complex logic
  return 'John';
}
```

### Tear-offs and Callback Signatures

- ✅ Prefer tear-offs when callback signatures match exactly
- ✅ Enable lints `unnecessary_lambdas` and `implicit_call_tearoffs`
- ✅ Keep lambdas when adapting args (`context`, `index`, named args)
- ❌ Do not force tear-offs when a lambda is required for clarity/correctness

```dart
// ✅ Good: method tear-off (same signature)
onPressed: _reloadData;

// ✅ Good: constructor tear-off when signature matches
final widgets = iconDataList.map(Icon.new).toList();

// ✅ Good: lambda is required to adapt parameters
itemBuilder: (context, index) => UserCard(user: users[index]);

// ❌ Avoid: unnecessary lambda
onPressed: () => _reloadData();
```

## Classes

### Constructors

- ✅ Use named constructors for different ways to create instances
- ✅ Use `super.key` to pass key to widgets
- ✅ Use `required` for required parameters in named constructors

```dart
// ✅ Good: named constructor
class User {
  final String name;
  final String email;

  User({required this.name, required this.email});

  User.anonymous() : name = 'Anonymous', email = '';

  User.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        email = json['email'];
}

// ✅ Good: super.key in widgets
class MyWidget extends StatelessWidget {
  const MyWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container();
  }
}
```

### Getters and Setters

Prefer getters/setters over methods when appropriate. Use getters for calculated values.

```dart
class Rectangle {
  final double width;
  final double height;

  Rectangle(this.width, this.height);

  // ✅ Good: getter for calculated value
  double get area => width * height;

  // ✅ Good: getter for derived property
  bool get isSquare => width == height;
}
```

## Dot Shorthands

Use dot shorthands for cascade operations and method calls for cleaner, more readable code.

```dart
// ✅ Good: cascade notation
final user = User()
  ..name = 'John'
  ..email = 'john@example.com'
  ..age = 30;

// ✅ Good: cascade with method calls
final list = <int>[]
  ..add(1)
  ..add(2)
  ..add(3);

// ✅ Good: cascade for builder pattern
final button = ElevatedButton(
  onPressed: () {},
  child: const Text('Click'),
)..style = ButtonStyle(
    backgroundColor: MaterialStateProperty.all(Colors.blue),
  );

// ✅ Good: dot shorthand for method calls
final numbers = [1, 2, 3];
numbers.map((n) => n * 2).toList();

// ✅ Good: dot shorthand with null-aware operators
user?.name?.toUpperCase();
```

## Formatting

### Use dart format

Always format your code using `dart format` (formerly `dartfmt`). It's the official formatter.

### Use dart fix

Prefer using `dart fix --apply` to apply safe, automated fixes (lint cleanup, small refactors) before committing larger changes.

### Run flutter analyze

Run `flutter analyze` after meaningful changes (especially refactors) to catch issues early and keep the codebase consistently clean.

### Line Length

Prefer lines at **80 characters or fewer**. Longer lines reduce readability.

### Curly Braces

Use braces for all blocks (`if`, `else`, `for`, etc.). Only omit braces for single-line `if` without `else` if the whole statement fits on one line.

```dart
// ✅ Good: always use braces
if (condition) {
  doSomething();
}

// ✅ Good: omit braces for single-line if without else
if (condition) doSomething();
```

## Show/Hide

Use `show` to import only what's necessary.

```dart
import 'package:my_package/my_package.dart' show User, UserService;
```

## Modern Dart 3+ Features

### Pattern Matching

Use pattern matching features where they simplify the code.

```dart
// ✅ Good: pattern matching in switch
import 'dart:developer' as developer;

switch (value) {
  case User(name: final name, age: >= 18):
    developer.log('$name is an adult');
  case User(name: final name):
    developer.log('$name is a minor');
}

// ✅ Good: pattern matching in if-case
if (user case User(age: final age)) {
  developer.log('User age: $age');
}

// ✅ Good: list and map patterns
final [first, second, ...rest] = items;
final {'name': final name, 'age': final age} = jsonMap;
```

### Records

Use records to return multiple types in situations where defining an entire class is cumbersome.

```dart
// ✅ Good: record for multiple return values
(String name, int age) getUserInfo() {
  return ('John', 30);
}

// Usage
final (name, age) = getUserInfo();

// ✅ Good: named record fields for clarity
({String name, int age}) getUserInfo() {
  return (name: 'John', age: 30);
}

// Usage with named fields
final (:name, :age) = getUserInfo();

// ✅ Good: record patterns in switch
switch (result) {
  case (success: true, data: final data):
    process(data);
  case (success: false, error: final error):
    handleError(error);
}
```

### Switch Statements

Prefer using exhaustive `switch` statements or expressions, which don't require `break` statements.

```dart
import 'dart:developer' as developer;

// ✅ Good: exhaustive switch (no break needed)
switch (status) {
  case Status.loading:
    showLoader();
  case Status.success:
    showContent();
  case Status.error:
    showError();
}

// ✅ Good: switch expression
final icon = switch (weather) {
  Weather.sunny => Icons.sun,
  Weather.cloudy => Icons.cloud,
  Weather.rainy => Icons.water_drop,
};

// ✅ Good: guard clauses in switch
switch (value) {
  case int _ when value > 0:
    developer.log('Positive');
  case int _ when value < 0:
    developer.log('Negative');
  case 0:
    developer.log('Zero');
}
```

### Comments Style

- ✅ Use comments only to explain "why", not "what"
- ✅ **Avoid trailing comments** - place comments above the code instead
- ✅ Keep comments updated with code
- ✅ Prefer clear code over comments
- ❌ Never add `// ignore` or `// ignore_for_file` unless it matches the allowlist in `error_handling.md`

```dart
// ✅ Good: comment above code
// Use local cache to reduce API calls by 80%
final cachedUser = await localCache.getUser(id);

// ❌ Avoid: trailing comment
final user = await cache.getUser(id); // Get user from cache

// ❌ Avoid: explains what (code already does this)
// Get user from cache
final user = await cache.getUser(id);
```

### JSON Serialization

Use `json_serializable` and `json_annotation` for parsing and encoding JSON data. Use `fieldRename: FieldRename.snake` to convert Dart's camelCase fields to snake_case JSON keys.

```dart
import 'package:json_annotation/json_annotation.dart';

part 'user.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class User {
  final String firstName;
  final String lastName;

  User({required this.firstName, required this.lastName});

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  Map<String, dynamic> toJson() => _$UserToJson(this);
}
```

### Code Generation (build_runner)

Use `build_runner` for code generation tasks (e.g., `json_serializable`). After changing annotated models, re-run codegen:

```shell
dart run build_runner build --delete-conflicting-outputs
```

### Class Organization

Define related classes within the same library file. For large libraries, export smaller, private libraries from a single top-level library.

```dart
// ✅ Good: related classes in same file
class User {
  final String name;
  User(this.name);
}

class AdminUser extends User {
  final List<String> permissions;
  AdminUser(super.name, this.permissions);
}

// ✅ Good: export from top-level library
// library.dart
export 'src/user.dart';
export 'src/admin_user.dart';
export 'src/services/user_service.dart';
```

### Async/Await Best Practices

Ensure proper use of `async`/`await` for asynchronous operations with robust error handling.

```dart
// ✅ Good: proper error handling
Future<User> getUser(String id) async {
  try {
    final response = await http.get('/users/$id');
    return User.fromJson(response.data);
  } on SocketException catch (e) {
    throw NetworkException('No internet connection');
  } on HttpException catch (e) {
    throw ServerException('Server error: ${e.message}');
  } catch (e) {
    throw UnknownException(e.toString());
  }
}

// ✅ Good: use Future.value for synchronous returns
Future<String> getUserName() {
  return Future.value('John');
}

// ✅ Good: use Future.error for exceptions
Future<String> fail() {
  return Future.error(Exception('Failed'));
}
```

### Streams

Use `Stream`s for sequences of asynchronous events.

```dart
import 'dart:developer' as developer;

// ✅ Good: stream for multiple values
Stream<int> counter() async* {
  for (int i = 0; i < 10; i++) {
    yield i;
  }
}

// ✅ Good: stream controller for manual control
final controller = StreamController<String>();

controller.add('First');
controller.add('Second');
await controller.close();

await for (final value in controller.stream) {
  developer.log(value);
}
```

### Logging

Use the `log` function from `dart:developer` for structured logging that integrates with Dart DevTools.

```dart
import 'dart:developer' as developer;

// Simple messages
developer.log('User logged in successfully.');

// Structured error logging
try {
  // ... code that might fail
} catch (e, s) {
  developer.log(
    'Failed to fetch data',
    name: 'myapp.network',
    level: 1000, // SEVERE
    error: e,
    stackTrace: s,
  );
}
```

## General Best Practices

### Avoid Dead Code

- ✅ Remove unused commented code
- ✅ Remove unused imports
- ✅ Remove unused variables

### Performance

- ✅ Use `const` constructors when possible
- ✅ Avoid unnecessary rebuilds
- ✅ Use `const` widgets when possible

### Readability

- ✅ Keep functions small and focused
- ✅ Use descriptive names
- ✅ Avoid excessive nesting depth
- ✅ Break long lines (maximum ~80 characters)

### Avoid Leading Underscores

Don't use leading underscores for non-private identifiers (locals, parameters, library prefixes) - underscores are reserved for privacy at top-level or inside libraries.

## References

For more details, see the official [Effective Dart: Style Guide](https://dart.dev/effective-dart/style).


