import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/editor/editor.dart';

/// What the library remembers about each note besides its file:
/// whether it's a favorite, and which cover it's shown with.
///
/// Notes are identified by their path without the file extension,
/// e.g. `/Maths/Chapter 1`.
abstract final class NoteLibrary {
  /// The colors that a note's cover can have.
  static const coverColors = <Color>[
    Color(0xFF2F3E55), // navy
    Color(0xFF3B7DD8), // blue
    Color(0xFF2E9E8F), // teal
    Color(0xFF5BA84A), // green
    Color(0xFFE2B33C), // yellow
    Color(0xFFE5783B), // orange
    Color(0xFFD9485F), // red
    Color(0xFF8E5BC7), // purple
    Color(0xFF7A6652), // brown
    Color(0xFF4A4A4A), // charcoal
  ];

  /// Removes the file extension of a note from [path], if it has one.
  static String notePath(String path) {
    for (final extension in [Editor.extension, Editor.extensionOldJson]) {
      if (path.endsWith(extension)) {
        return path.substring(0, path.length - extension.length);
      }
    }
    return path;
  }

  static bool isFavorite(String path) =>
      stows.favoriteNotes.value.contains(notePath(path));

  static void setFavorite(String path, bool favorite) {
    path = notePath(path);
    final favorites = stows.favoriteNotes.value.toList();
    if (favorite == favorites.contains(path)) return;
    if (favorite) {
      favorites.insert(0, path);
    } else {
      favorites.remove(path);
    }
    stows.favoriteNotes.value = favorites;
    _recordChange(path);
  }

  static Map<String, int> get _covers {
    try {
      return (jsonDecode(stows.noteCovers.value) as Map).cast();
    } catch (e) {
      return {};
    }
  }

  /// Returns the color of the cover of the note at [path],
  /// or null if the note is shown as a preview of its first page.
  static Color? coverOf(String path) {
    final index = _covers[notePath(path)];
    if (index == null || index < 0 || index >= coverColors.length) return null;
    return coverColors[index];
  }

  /// Gives the note at [path] a cover of the given [color],
  /// which must be one of [coverColors], or no cover if [color] is null.
  static void setCover(String path, Color? color) {
    path = notePath(path);
    final covers = _covers;
    final index = color == null ? -1 : coverColors.indexOf(color);
    if (index < 0) {
      if (covers.remove(path) == null) return;
    } else {
      if (covers[path] == index) return;
      covers[path] = index;
    }
    stows.noteCovers.value = jsonEncode(covers);
    _recordChange(path);
  }

  /// Call this when a note has been moved or renamed.
  static void noteRenamed(String fromPath, String toPath) {
    fromPath = notePath(fromPath);
    toPath = notePath(toPath);
    if (fromPath == toPath) return;

    final favorites = stows.favoriteNotes.value.toList();
    final index = favorites.indexOf(fromPath);
    if (index >= 0) {
      favorites
        ..remove(toPath)
        ..[favorites.indexOf(fromPath)] = toPath;
      stows.favoriteNotes.value = favorites;
    }

    final covers = _covers;
    final cover = covers.remove(fromPath);
    if (cover != null) {
      covers[toPath] = cover;
      stows.noteCovers.value = jsonEncode(covers);
    }

    _recordChange(fromPath);
    _recordChange(toPath);
  }

  /// Call this when a note has been deleted.
  static void noteRemoved(String path) {
    setFavorite(path, false);
    setCover(path, null);
  }

  static Map<String, Map<String, dynamic>> get _changes {
    try {
      return (jsonDecode(stows.noteLibraryChanges.value) as Map).map(
        (path, entry) =>
            MapEntry(path as String, Map<String, dynamic>.from(entry as Map)),
      );
    } catch (e) {
      return {};
    }
  }

  /// The favorite and cover of the note at [path] as they're synced.
  static Map<String, dynamic> _entryOf(String path, {required int time}) => {
    'f': stows.favoriteNotes.value.contains(path),
    'c': _covers[path] ?? -1,
    't': time,
  };

  /// Takes note that the favorite or cover of [path] changed on this device,
  /// so that the change is sent to the account's other devices.
  static void _recordChange(String path) {
    final changes = _changes;
    final previous = changes[path]?['t'] as int? ?? 0;
    // later than any change we know of, even if the clock went back
    final time = max(DateTime.now().millisecondsSinceEpoch, previous + 1);
    changes[path] = _entryOf(path, time: time);
    stows.noteLibraryChanges.value = jsonEncode(changes);
    final unsent = stows.noteLibraryUnsent.value;
    if (!unsent.contains(path)) {
      stows.noteLibraryUnsent.value = [...unsent, path];
    }
  }

  /// Forgets when each favorite and cover changed, e.g. when switching to
  /// another account, so that they're sent to it as older than its own.
  static void forgetChangeTimes() => stows.noteLibraryChanges.value = '{}';

  /// The notes that are favorites or have a cover.
  static List<String> get allPaths =>
      {...stows.favoriteNotes.value, ..._covers.keys}.toList();

  /// Records the favorites and covers that were set before they were synced,
  /// as older than any change made since, so that they're sent once.
  static void _recordUntrackedEntries() {
    final changes = _changes;
    final untracked = [
      for (final path in allPaths)
        if (!changes.containsKey(path)) path,
    ];
    if (untracked.isEmpty) return;
    for (final path in untracked) {
      changes[path] = _entryOf(path, time: 1);
    }
    stows.noteLibraryChanges.value = jsonEncode(changes);
    stows.noteLibraryUnsent.value = {
      ...stows.noteLibraryUnsent.value,
      ...untracked,
    }.toList();
  }

  /// The changes that the server hasn't got yet, to send it.
  static Map<String, Map<String, dynamic>> get unsentChanges {
    _recordUntrackedEntries();
    final changes = _changes;
    return {
      for (final path in stows.noteLibraryUnsent.value) path: ?changes[path],
    };
  }

  /// Applies the changes that the server has, which include those that
  /// other devices made, and takes note that the [sent] ones arrived.
  static void applyRemoteChanges(
    Map<String, dynamic> remote, {
    required Map<String, Map<String, dynamic>> sent,
  }) {
    final changes = _changes;
    // a change made while the others were on their way is sent next time
    stows.noteLibraryUnsent.value = [
      for (final path in stows.noteLibraryUnsent.value)
        if (sent[path]?['t'] != changes[path]?['t']) path,
    ];

    final favorites = stows.favoriteNotes.value.toList();
    final covers = _covers;
    var changed = false;
    for (final MapEntry(key: path, value: entry) in remote.entries) {
      if (entry is! Map) continue;
      final time = (entry['t'] as num?)?.toInt() ?? 0;
      if (time <= ((changes[path]?['t'] as num?)?.toInt() ?? 0)) continue;
      changed = true;
      changes[path] = Map<String, dynamic>.from(entry);

      final favorite = entry['f'] == true;
      if (favorite != favorites.contains(path)) {
        favorite ? favorites.insert(0, path) : favorites.remove(path);
      }
      final cover = (entry['c'] as num?)?.toInt() ?? -1;
      if (cover < 0 || cover >= coverColors.length) {
        covers.remove(path);
      } else {
        covers[path] = cover;
      }
    }
    if (!changed) return;
    stows.noteLibraryChanges.value = jsonEncode(changes);
    stows.favoriteNotes.value = favorites;
    stows.noteCovers.value = jsonEncode(covers);
  }
}
