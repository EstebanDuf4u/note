import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saber/data/sync/realtime/realtime_account.dart';
import 'package:saber/data/sync/realtime/shared_notes.dart';
import 'package:saber/i18n/strings.g.dart';

/// Lets the user share the note at [path] with others through a link,
/// or shows who shared it if it's another account's note.
class ShareDialog extends StatefulWidget {
  const new({super.key, required this.path});

  final String path;

  static Future<void> show(BuildContext context, String path) => showDialog(
    context: context,
    builder: (context) => ShareDialog(path: path),
  );

  @override
  State<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<ShareDialog> {
  String? _link;
  String? _error;
  var _busy = false;

  late final _sharedNote = SharedNotes.at(widget.path);

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on RealtimeAccountException catch (e) {
      _error = e.code == RealtimeAccountException.unreachable
          ? t.sharing.offline
          : t.sharing.failed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() => _run(() async {
    final token = await RealtimeAccount.shareNote(widget.path);
    _link = SharedNotes.linkOf(token);
  });

  Future<void> _unshare() => _run(() async {
    await RealtimeAccount.unshareNote(widget.path);
    _link = null;
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);
    final sharedNote = _sharedNote;

    return AlertDialog(
      icon: Icon(Icons.group_add, color: colorScheme.primary),
      title: Text(t.sharing.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .stretch,
          spacing: 12,
          children: [
            if (sharedNote != null)
              Text(t.sharing.sharedBy(owner: sharedNote.owner))
            else ...[
              Text(t.sharing.description, style: textTheme.bodyMedium),
              if (_link case final link?)
                Container(
                  padding: const .only(left: 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: .circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          link,
                          maxLines: 1,
                          style: textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        tooltip: t.sharing.copy,
                        icon: const Icon(Icons.copy),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: link));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(t.sharing.copied)),
                          );
                        },
                      ),
                    ],
                  ),
                ),
            ],
            if (_error case final error?)
              Text(error, style: TextStyle(color: colorScheme.error)),
          ],
        ),
      ),
      actions: [
        if (sharedNote == null && _link != null)
          TextButton(
            onPressed: _busy ? null : _unshare,
            child: Text(t.sharing.stop),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.sharing.close),
        ),
        if (sharedNote == null && _link == null)
          FilledButton.icon(
            onPressed: _busy ? null : _share,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link),
            label: Text(t.sharing.createLink),
          ),
      ],
    );
  }
}

/// Asks the user for a link that someone shared, and opens its note.
class OpenSharedLinkDialog extends StatefulWidget {
  const new({super.key, required this.open});

  /// Opens the note, and returns its path on this device.
  final Future<String> Function(String link) open;

  /// Returns the path of the opened note, if one was opened.
  static Future<String?> show(
    BuildContext context,
    Future<String> Function(String link) open,
  ) => showDialog<String>(
    context: context,
    builder: (context) => OpenSharedLinkDialog(open: open),
  );

  @override
  State<OpenSharedLinkDialog> createState() => _OpenSharedLinkDialogState();
}

class _OpenSharedLinkDialogState extends State<OpenSharedLinkDialog> {
  final _controller = TextEditingController();
  String? _error;
  var _busy = false;

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await widget.open(_controller.text);
      if (mounted) Navigator.pop(context, path);
    } on RealtimeAccountException catch (e) {
      setState(() {
        _error = switch (e.code) {
          RealtimeAccountException.unreachable => t.sharing.offline,
          RealtimeAccountException.notFound => t.sharing.invalidLink,
          _ => t.sharing.failed,
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.link),
      title: Text(t.sharing.openLink),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: t.sharing.linkHint,
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _open(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.sharing.close),
        ),
        FilledButton(
          onPressed: _busy ? null : _open,
          child: Text(t.sharing.open),
        ),
      ],
    );
  }
}
