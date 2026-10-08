import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/home/notebook_cover.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/data/note_library.dart';
import 'package:saber/i18n/strings.g.dart';

/// Lets the user choose the cover of the selected notes.
class const CoverNoteButton({
  super.key,
  required final List<String> selectedFiles,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      padding: EdgeInsets.zero,
      tooltip: t.home.cover.change,
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => _CoverDialog(selectedFiles: selectedFiles),
      ),
      icon: const Icon(Icons.palette_outlined),
    );
  }
}

class const _CoverDialog({required final List<String> selectedFiles})
    extends StatelessWidget {
  void _choose(BuildContext context, Color? color) {
    for (final filePath in selectedFiles) {
      NoteLibrary.setCover(filePath, color);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final current = selectedFiles.length == 1
        ? NoteLibrary.coverOf(selectedFiles.single)
        : null;
    final title = selectedFiles.length == 1
        ? selectedFiles.single.substring(
            selectedFiles.single.lastIndexOf('/') + 1,
          )
        : '';

    Widget option(Color? color) => SizedBox(
      width: 72,
      child: InkWell(
        borderRadius: .circular(8),
        onTap: () => _choose(context, color),
        child: Padding(
          padding: const .all(6),
          child: NotebookCover(
            title: title,
            color: color,
            selected: selectedFiles.length == 1 && color == current,
            preview: ColoredBox(
              color: Colors.white,
              child: Center(
                child: Padding(
                  padding: const .all(6),
                  child: Text(
                    t.home.cover.firstPage,
                    textAlign: .center,
                    style: const TextStyle(
                      color: Color(0xFF555555),
                      fontSize: 10,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return AdaptiveAlertDialog(
      title: Text(t.home.cover.title),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Wrap(
            alignment: .center,
            spacing: 4,
            runSpacing: 4,
            children: [
              option(null),
              for (final color in NoteLibrary.coverColors) option(color),
            ],
          ),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.common.cancel),
        ),
      ],
    );
  }
}
