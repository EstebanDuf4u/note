import 'dart:convert';

import 'package:saber/data/note_library.dart';
import 'package:saber/data/prefs.dart';

/// A note of another account that the user opened from its link.
class SharedNote {
  const new({
    required this.token,
    required this.owner,
    required this.ownerPath,
    required this.localPath,
    this.left = false,
  });

  factory fromJson(String token, Map<String, dynamic> json) => SharedNote(
    token: token,
    owner: json['owner'] as String? ?? '',
    ownerPath: json['path'] as String? ?? '',
    localPath: json['local'] as String,
    left: json['left'] == true,
  );

  /// The token of the note's link, which is how it's opened on the server.
  final String token;

  /// The name of the account that the note belongs to.
  final String owner;

  /// Where the note is in its owner's library.
  final String ownerPath;

  /// Where the note is in this device's library, without its extension.
  final String localPath;

  /// Whether the user removed the note, but the server hasn't been told yet.
  final bool left;

  Map<String, dynamic> toJson() => {
    'owner': owner,
    'path': ownerPath,
    'local': localPath,
    if (left) 'left': true,
  };

  SharedNote copyWith({String? localPath, bool? left}) => SharedNote(
    token: token,
    owner: owner,
    ownerPath: ownerPath,
    localPath: localPath ?? this.localPath,
    left: left ?? this.left,
  );
}

/// The notes of other accounts that the user opened from their links.
///
/// They're synced with their owner's note rather than with the user's
/// account, so they're kept apart from the user's own notes.
abstract final class SharedNotes {
  /// The folder that shared notes are put in.
  static const folder = '/Partagés';

  static Map<String, SharedNote> get all {
    try {
      final json = jsonDecode(stows.sharedNotes.value) as Map<String, dynamic>;
      return {
        for (final MapEntry(:key, :value) in json.entries)
          key: SharedNote.fromJson(key, value as Map<String, dynamic>),
      };
    } catch (e) {
      return {};
    }
  }

  static void _save(Map<String, SharedNote> notes) =>
      stows.sharedNotes.value = jsonEncode({
        for (final MapEntry(:key, :value) in notes.entries) key: value.toJson(),
      });

  /// Returns the shared note at [localPath], if it's one the user hasn't left.
  static SharedNote? at(String localPath) {
    localPath = NoteLibrary.notePath(localPath);
    for (final note in all.values) {
      if (note.localPath == localPath && !note.left) return note;
    }
    return null;
  }

  /// Returns the token of the link of the note at [localPath],
  /// or null if it's one of the user's own notes.
  static String? tokenAt(String localPath) => at(localPath)?.token;

  static bool isShared(String localPath) => at(localPath) != null;

  /// Takes note of a shared note, putting it in [folder] under a name that
  /// isn't taken by [isTaken], and returns it.
  static SharedNote add({
    required String token,
    required String owner,
    required String ownerPath,
    required bool Function(String path) isTaken,
  }) {
    final notes = all;
    if (notes[token] case final existing? when !existing.left) return existing;

    final name = ownerPath.substring(ownerPath.lastIndexOf('/') + 1);
    final base = '$folder/$name ($owner)';
    var localPath = base;
    for (int i = 2; isTaken(localPath) || _isUsed(notes, localPath); ++i) {
      localPath = '$base $i';
    }
    final note = SharedNote(
      token: token,
      owner: owner,
      ownerPath: ownerPath,
      localPath: localPath,
    );
    notes[token] = note;
    _save(notes);
    return note;
  }

  static bool _isUsed(Map<String, SharedNote> notes, String localPath) =>
      notes.values.any((note) => note.localPath == localPath);

  /// Forgets the shared note with [token].
  static void remove(String token) {
    final notes = all;
    if (notes.remove(token) != null) _save(notes);
  }

  /// Takes note that the user removed the shared note at [localPath],
  /// so that the server is told. Returns whether it was a shared note.
  static bool leave(String localPath) {
    final note = at(localPath);
    if (note == null) return false;
    final notes = all;
    notes[note.token] = note.copyWith(left: true);
    _save(notes);
    return true;
  }

  /// Call this when a note was moved or renamed on this device.
  static void noteRenamed(String fromPath, String toPath) {
    final note = at(fromPath);
    if (note == null) return;
    final notes = all;
    notes[note.token] = note.copyWith(localPath: NoteLibrary.notePath(toPath));
    _save(notes);
  }

  /// Returns the token in a link like `https://server/s/<token>`,
  /// or [link] itself if it's just the token.
  static String? tokenOfLink(String link) {
    link = link.trim();
    if (link.isEmpty) return null;
    final uri = Uri.tryParse(link);
    final segments = uri?.pathSegments ?? const [];
    final index = segments.indexOf('s');
    if (index >= 0 && index + 1 < segments.length) return segments[index + 1];
    if (link.contains('/') || link.contains(' ')) return null;
    return link;
  }

  /// Returns the link to give to others to open the note shared as [token].
  static String linkOf(String token) => '${stows.realtimeUrl.value}/s/$token';
}
