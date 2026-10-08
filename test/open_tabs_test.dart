import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/open_tabs.dart';
import 'package:saber/data/prefs.dart';

void main() {
  FlavorConfig.setup();
  setUp(() => stows.openTabs.value = []);

  test('notes open as tabs next to the one they were opened from', () {
    OpenTabs.open('/a.sbn2');
    OpenTabs.open('/b');
    OpenTabs.open('/c', after: '/a');
    OpenTabs.open('/b'); // already open
    expect(OpenTabs.paths, ['/a', '/c', '/b']);
    expect(OpenTabs.lastShown, '/b');

    // the whiteboard isn't a tab
    OpenTabs.open('/_whiteboard');
    expect(OpenTabs.paths, hasLength(3));
  });

  test('closing a tab returns the one that takes its place', () {
    stows.openTabs.value = ['/a', '/b', '/c'];
    expect(OpenTabs.close('/b'), '/c');
    expect(OpenTabs.close('/c'), '/a');
    expect(OpenTabs.close('/a'), isNull);
    expect(OpenTabs.paths, isEmpty);
  });

  test('tabs follow renamed and deleted notes', () {
    stows.openTabs.value = ['/a', '/b'];
    OpenTabs.noteRenamed('/a.sbn2', '/folder/a2.sbn2');
    expect(OpenTabs.paths, ['/folder/a2', '/b']);
    OpenTabs.noteRemoved('/b.sbn2');
    expect(OpenTabs.paths, ['/folder/a2']);
  });

  test('the oldest tab is closed when there are too many', () {
    for (int i = 0; i <= OpenTabs.maxTabs; i++) {
      OpenTabs.open('/$i');
    }
    expect(OpenTabs.paths, hasLength(OpenTabs.maxTabs));
    expect(OpenTabs.paths.first, '/1');
  });
}
