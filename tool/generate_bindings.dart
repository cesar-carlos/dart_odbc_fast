import 'dart:io';

void main() async {
  print('Generating ODBC bindings...');

  final result = await Process.run(
    'dart',
    ['run', 'ffigen', '--config', 'ffigen.yaml'],
  );

  if (result.exitCode == 0) {
    print('Bindings generated successfully!');
    print(result.stdout);
  } else {
    print('Error generating bindings:');
    print(result.stderr);
    exit(result.exitCode);
  }
}
