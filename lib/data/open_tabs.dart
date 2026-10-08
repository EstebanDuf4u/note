import 'package:saber/data/note_library.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/home/whiteboard.dart';

/// The notes that are open as tabs in the editor, so that the user can
/// switch between them. Like [NoteLibrary], notes are identified by their
/// path without the file extension.
abstract final class OpenTabs {
  /// How many tabs are kept: opening another closes the oldest.
  static const maxTabs = 12;

  static List<String> get paths => stows.openTabs.value;

  /// The tab of the note that was opened last.
  static String? lastShown;

  /// Adds a tab for the note at [path], after the tab of [after] if given,
  /// unless it already has one.
  static void open(String path, {String? after}) {
    path = NoteLibrary.notePath(path);
    if (path == Whiteboard.filePath) return;
    lastShown = path;
    final tabs = paths.toList();
    if (tabs.contains(path)) return;
    final index = after == null
        ? -1
        : tabs.indexOf(NoteLibrary.notePath(after));
    tabs.insert(index < 0 ? tabs.length : index + 1, path);
    while (tabs.length > maxTabs) {
      tabs.removeAt(tabs.first == path ? 1 : 0);
    }
    stows.openTabs.value = tabs;
  }

  /// Closes the tab of [path], and returns the tab that takes its place,
  /// if there's one left.
  static String? close(String path) {
    path = NoteLibrary.notePath(path);
    final tabs = paths.toList();
    final index = tabs.indexOf(path);
    if (index < 0) return tabs.lastOrNull;
    tabs.removeAt(index);
    stows.openTabs.value = tabs;
    if (tabs.isEmpty) return null;
    return tabs[index.clamp(0, tabs.length - 1)];
  }

  /// Moves the tab at [oldIndex] to [newIndex].
  static void reorder(int oldIndex, int newIndex) {
    final tabs = paths.toList();
    tabs.insert(newIndex, tabs.removeAt(oldIndex));
    stows.openTabs.value = tabs;
  }

  /// Call this when a note has been moved or renamed.
  static void noteRenamed(String fromPath, String toPath) {
    fromPath = NoteLibrary.notePath(fromPath);
    toPath = NoteLibrary.notePath(toPath);
    final tabs = paths.toList();
    final index = tabs.indexOf(fromPath);
    if (index < 0) return;
    tabs
      ..remove(toPath)
      ..[tabs.indexOf(fromPath)] = toPath;
    stows.openTabs.value = tabs;
  }

  /// Call this when a note has been deleted.
  static void noteRemoved(String path) {
    path = NoteLibrary.notePath(path);
    if (!paths.contains(path)) return;
    stows.openTabs.value = [
      for (final tab in paths)
        if (tab != path) tab,
    ];
  }
}
