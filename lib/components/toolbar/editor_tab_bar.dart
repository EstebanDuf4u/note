import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/note_library.dart';
import 'package:saber/data/open_tabs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/i18n/strings.g.dart';

/// The notes that are open as tabs, shown above the editor
/// so that the user can switch between them.
class EditorTabBar extends StatelessWidget implements PreferredSizeWidget {
  const new({super.key, required this.currentPath});

  /// The note that is open in this editor.
  final String currentPath;

  static const height = 40.0;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  /// Opens the note at [path] in place of the current one.
  static void switchTo(BuildContext context, String path) =>
      context.pushReplacement(RoutePaths.editFilePath(path));

  void _close(BuildContext context, String path) {
    final isCurrent = path == NoteLibrary.notePath(currentPath);
    final next = OpenTabs.close(path);
    if (!isCurrent) return;
    if (next != null) {
      switchTo(context, next);
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final current = NoteLibrary.notePath(currentPath);
    return ValueListenableBuilder(
      valueListenable: stows.openTabs,
      builder: (context, tabs, _) {
        return SizedBox(
          height: height,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            padding: const .symmetric(horizontal: 8),
            itemCount: tabs.length,
            onReorderItem: OpenTabs.reorder,
            itemBuilder: (context, index) {
              final path = tabs[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(path),
                index: index,
                child: _Tab(
                  name: p.basename(path),
                  color: NoteLibrary.coverOf(path),
                  selected: path == current,
                  colorScheme: colorScheme,
                  onTap: path == current ? null : () => switchTo(context, path),
                  onClose: () => _close(context, path),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const new({
    required this.name,
    required this.color,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
    required this.onClose,
  });

  final String name;
  final Color? color;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback? onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? colorScheme.onSurface
        : colorScheme.onSurfaceVariant;
    return Padding(
      padding: const .only(right: 4, top: 6),
      child: Material(
        color: selected
            ? colorScheme.surface
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: const .vertical(top: .circular(10)),
          side: selected
              ? BorderSide(color: colorScheme.outlineVariant)
              : BorderSide.none,
        ),
        clipBehavior: .antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 200),
            child: Padding(
              padding: const .only(left: 12, right: 2),
              child: Row(
                mainAxisSize: .min,
                spacing: 8,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: .circle,
                      color: color ?? colorScheme.primary,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      name,
                      overflow: .ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: selected ? .w600 : .w400,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: t.editor.closeTab,
                    visualDensity: .compact,
                    iconSize: 16,
                    color: foreground,
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
