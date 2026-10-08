import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/app_id_migration.dart';

void main() {
  late Directory dataHome;
  File oldFile(String name) =>
      File('${dataHome.path}/${AppIdMigration.oldAppId}/$name');
  File newFile(String name) =>
      File('${dataHome.path}/${AppIdMigration.appId}/$name');

  setUp(() {
    dataHome = Directory.systemTemp.createTempSync('noteplus_app_id');
  });
  tearDown(() => dataHome.deleteSync(recursive: true));

  test('the settings follow the app to its new id', () {
    oldFile('shared_preferences.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"flutter.realtimeUrl":"http://example"}');
    oldFile('sub/other').createSync(recursive: true);

    AppIdMigration.run(dataHome: dataHome.path);
    expect(
      newFile('shared_preferences.json').readAsStringSync(),
      '{"flutter.realtimeUrl":"http://example"}',
    );
    expect(newFile('sub/other').existsSync(), isTrue);
    expect(
      oldFile('shared_preferences.json').existsSync(),
      isTrue,
      reason: 'The old settings are kept',
    );
  }, testOn: 'linux');

  test('settings saved under the new id are not replaced', () {
    oldFile('shared_preferences.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    newFile('shared_preferences.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('new');

    AppIdMigration.run(dataHome: dataHome.path);
    expect(newFile('shared_preferences.json').readAsStringSync(), 'new');
  }, testOn: 'linux');

  test('nothing happens when there are no old settings', () {
    AppIdMigration.run(dataHome: dataHome.path);
    expect(
      Directory('${dataHome.path}/${AppIdMigration.appId}').existsSync(),
      isFalse,
    );
  }, testOn: 'linux');
}
