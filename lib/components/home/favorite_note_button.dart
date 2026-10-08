import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:saber/data/note_library.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';

/// Adds the selected notes to the favorites,
/// or removes them if they're all favorites already.
class const FavoriteNoteButton({
  super.key,
  required final List<String> selectedFiles,
}) extends HookWidget {
  @override
  Widget build(BuildContext context) {
    useListenable(stows.favoriteNotes);
    final allFavorites = selectedFiles.every(NoteLibrary.isFavorite);

    return IconButton(
      padding: EdgeInsets.zero,
      tooltip: allFavorites
          ? t.home.removeFromFavorites
          : t.home.addToFavorites,
      onPressed: () {
        for (final filePath in selectedFiles) {
          NoteLibrary.setFavorite(filePath, !allFavorites);
        }
      },
      icon: Icon(
        allFavorites ? Icons.star_rounded : Icons.star_outline_rounded,
      ),
    );
  }
}
