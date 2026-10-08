import 'dart:io';

import 'package:logging/logging.dart';

/// Note+ used Saber's application id (`com.adilhanney.saber`) at first.
/// On Linux, the app's settings are stored in a folder named after that id,
/// so they need to follow the app to its own id.
abstract final class AppIdMigration {
  static final log = Logger('AppIdMigration');

  static const oldAppId = 'com.adilhanney.saber';
  static const appId = 'fr.noryx.noteplus';

  /// Copies the settings saved under [oldAppId] to [appId],
  /// unless there are settings under [appId] already.
  ///
  /// This must run before the settings are first read.
  /// The old folder is left as it is.
  ///
  /// [dataHome] is where applications keep their data,
  /// which is `~/.local/share` unless the user changed it.
  static void run({String? dataHome}) {
    if (!Platform.isLinux) return;
    try {
      dataHome ??=
          Platform.environment['XDG_DATA_HOME'] ??
          '${Platform.environment['HOME']}/.local/share';
      final oldDirectory = Directory('$dataHome/$oldAppId');
      final newDirectory = Directory('$dataHome/$appId');
      if (!oldDirectory.existsSync()) return;
      if (File('${newDirectory.path}/shared_preferences.json').existsSync()) {
        return;
      }

      for (final entity in oldDirectory.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relativePath = entity.path.substring(oldDirectory.path.length);
        final copy = File('${newDirectory.path}$relativePath');
        if (copy.existsSync()) continue;
        copy.parent.createSync(recursive: true);
        entity.copySync(copy.path);
      }
    } catch (e, st) {
      // The app is still usable with the default settings.
      log.severe('Failed to copy the settings from $oldAppId: $e', e, st);
    }
  }
}
