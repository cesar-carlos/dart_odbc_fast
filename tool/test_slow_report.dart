import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int _defaultTop = 20;
const int _defaultThresholdMs = 0;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final result = await _runDartTest(options.testArgs);

  final slowTests = result.completedTests
      .where((test) => test.elapsedMs >= options.thresholdMs)
      .toList()
    ..sort((a, b) => b.elapsedMs.compareTo(a.elapsedMs));

  final shown = slowTests.take(options.top).toList();

  stdout.writeln('Slow test report');
  stdout.writeln(
      'Command: dart test --reporter json ${options.testArgs.join(' ')}');
  stdout.writeln('Exit code: ${result.exitCode}');
  stdout.writeln('Completed tests: ${result.completedTests.length}');
  stdout.writeln(
      'Showing top ${shown.length} tests >= ${options.thresholdMs} ms');
  if (options.failThresholdMs != null) {
    stdout.writeln('Fail threshold: ${options.failThresholdMs} ms');
  }
  stdout.writeln('');
  stdout.writeln('| ms | suite | test | result |');
  stdout.writeln('|---:|---|---|---|');
  for (final test in shown) {
    stdout.writeln(
      '| ${test.elapsedMs} | ${_escape(test.suitePath)} | '
      '${_escape(test.name)} | ${_escape(test.result)} |',
    );
  }

  final violations = options.failThresholdMs == null
      ? const <_CompletedTest>[]
      : (result.completedTests
          .where((test) => test.elapsedMs > options.failThresholdMs!)
          .toList()
        ..sort((a, b) => b.elapsedMs.compareTo(a.elapsedMs)));

  if (violations.isNotEmpty) {
    stderr.writeln('');
    stderr.writeln(
      'Slow-test budget exceeded: ${violations.length} test(s) above '
      '${options.failThresholdMs} ms.',
    );
    for (final test in violations.take(options.top)) {
      stderr.writeln(
        '- ${test.elapsedMs} ms ${test.suitePath}: ${test.name}',
      );
    }
  }

  if (result.exitCode != 0 || violations.isNotEmpty) {
    exitCode = result.exitCode;
    if (exitCode == 0) {
      exitCode = 1;
    }
  }
}

Future<_RunResult> _runDartTest(List<String> testArgs) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    <String>['test', '--reporter', 'json', ...testArgs],
    runInShell: true,
  );

  final suites = <int, String>{};
  final tests = <int, _StartedTest>{};
  final starts = <int, int>{};
  final completed = <_CompletedTest>[];

  final stdoutDone = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    _handleJsonLine(line, suites, tests, starts, completed);
  }).asFuture<void>();

  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stderr.writeln)
      .asFuture<void>();

  final exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutDone, stderrDone]);

  return _RunResult(exitCode: exitCode, completedTests: completed);
}

void _handleJsonLine(
  String line,
  Map<int, String> suites,
  Map<int, _StartedTest> tests,
  Map<int, int> starts,
  List<_CompletedTest> completed,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    return;
  }
  if (decoded is! Map<String, Object?>) {
    return;
  }

  final type = decoded['type'];
  if (type == 'suite') {
    final suite = decoded['suite'];
    if (suite is Map<String, Object?>) {
      final id = suite['id'];
      final path = suite['path'];
      if (id is int && path is String) {
        suites[id] = path;
      }
    }
    return;
  }

  if (type == 'testStart') {
    final test = decoded['test'];
    final time = decoded['time'];
    if (test is Map<String, Object?> && time is int) {
      final id = test['id'];
      final name = test['name'];
      final suiteId = test['suiteID'];
      if (id is int && name is String && suiteId is int) {
        tests[id] = _StartedTest(
          name: name,
          suitePath: suites[suiteId] ?? 'suite#$suiteId',
        );
        starts[id] = time;
      }
    }
    return;
  }

  if (type == 'testDone') {
    final testId = decoded['testID'];
    final time = decoded['time'];
    final result = decoded['result'];
    if (testId is int && time is int && result is String) {
      final started = tests[testId];
      final startedAt = starts[testId];
      if (started != null && startedAt != null) {
        completed.add(
          _CompletedTest(
            elapsedMs: time - startedAt,
            suitePath: started.suitePath,
            name: started.name,
            result: result,
          ),
        );
      }
    }
  }
}

String _escape(String value) {
  return value.replaceAll('|', r'\|').replaceAll('\n', ' ');
}

class _Options {
  const _Options({
    required this.top,
    required this.thresholdMs,
    required this.failThresholdMs,
    required this.testArgs,
  });

  factory _Options.parse(List<String> args) {
    var top = _defaultTop;
    var thresholdMs = _defaultThresholdMs;
    int? failThresholdMs;
    final testArgs = <String>[];

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--') {
        testArgs.addAll(args.skip(i + 1));
        break;
      }
      if (arg == '--top' && i + 1 < args.length) {
        top = int.tryParse(args[++i]) ?? top;
        continue;
      }
      if (arg == '--threshold-ms' && i + 1 < args.length) {
        thresholdMs = int.tryParse(args[++i]) ?? thresholdMs;
        continue;
      }
      if (arg == '--fail-threshold-ms' && i + 1 < args.length) {
        failThresholdMs = int.tryParse(args[++i]);
        continue;
      }
      testArgs.add(arg);
    }

    return _Options(
      top: top < 1 ? _defaultTop : top,
      thresholdMs: thresholdMs < 0 ? _defaultThresholdMs : thresholdMs,
      failThresholdMs: failThresholdMs == null || failThresholdMs < 1
          ? null
          : failThresholdMs,
      testArgs: testArgs,
    );
  }

  final int top;
  final int thresholdMs;
  final int? failThresholdMs;
  final List<String> testArgs;
}

class _RunResult {
  const _RunResult({
    required this.exitCode,
    required this.completedTests,
  });

  final int exitCode;
  final List<_CompletedTest> completedTests;
}

class _StartedTest {
  const _StartedTest({
    required this.name,
    required this.suitePath,
  });

  final String name;
  final String suitePath;
}

class _CompletedTest {
  const _CompletedTest({
    required this.elapsedMs,
    required this.suitePath,
    required this.name,
    required this.result,
  });

  final int elapsedMs;
  final String suitePath;
  final String name;
  final String result;
}
