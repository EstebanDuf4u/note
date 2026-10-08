import 'dart:convert';

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
  }

  /// Call this when a note has been deleted.
  static void noteRemoved(String path) {
    setFavorite(path, false);
    setCover(path, null);
  }
}
