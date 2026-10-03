import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('should_keep_derived_views_alive_after_parent_collection', () async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--enable-vm-service=0',
      '--disable-service-auth-codes',
      'run',
      'test/helpers/protocol_gc_probe.dart',
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      expect(
        await process.exitCode.timeout(const Duration(seconds: 30)),
        0,
        reason: await errors,
      );
      expect(await output, contains('Retained views survived forced GC'));
    } finally {
      process.kill();
    }
  });
}
