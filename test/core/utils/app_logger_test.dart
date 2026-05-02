import 'package:logging/logging.dart';
import 'package:odbc_fast/core/utils/logger.dart';
import 'package:test/test.dart';

void main() {
  group('AppLogger', () {
    test('shorthand methods complete without throwing', () {
      AppLogger.initialize(level: Level.OFF);

      expect(() => AppLogger.info('i'), returnsNormally);
      expect(() => AppLogger.warning('w'), returnsNormally);
      expect(() => AppLogger.severe('s'), returnsNormally);
      expect(() => AppLogger.fine('f'), returnsNormally);
      expect(() => AppLogger.shout('sh'), returnsNormally);
    });

    test('logger getter triggers lazy initialization', () {
      expect(() => AppLogger.logger, returnsNormally);
      expect(AppLogger.logger.name, 'odbc_fast');
    });
  });
}
