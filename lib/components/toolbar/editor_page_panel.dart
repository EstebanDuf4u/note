import 'package:flutter/material.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/i18n/strings.g.dart';

/// A column of page thumbnails at the side of the editor,
/// to see where you are in the note and jump to another page.
class EditorPagePanel extends StatefulWidget {
  const new({
    super.key,
    required this.coreInfo,
    required this.transformationController,
    required this.getCurrentPageIndex,
    required this.onPageTap,
    required this.onEditBookmark,
  });

  final EditorCoreInfo coreInfo;

  /// Changes when the user scrolls the note.
  final TransformationController transformationController;
  final int Function() getCurrentPageIndex;
  final void Function(int pageIndex) onPageTap;

  /// Lets the user rename or remove the bookmark of a page.
  final void Function(int pageIndex) onEditBookmark;

  static const width = 136.0;

  @override
  State<EditorPagePanel> createState() => _EditorPagePanelState();
}

class _EditorPagePanelState extends State<EditorPagePanel> {
  late int currentPageIndex = widget.getCurrentPageIndex();

  /// Whether the bookmarked pages are listed instead of every page.
  var _showContents = false;

  @override
  void initState() {
    super.initState();
    widget.transformationController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(EditorPagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transformationController != widget.transformationController) {
      oldWidget.transformationController.removeListener(_onScroll);
      widget.transformationController.addListener(_onScroll);
    }
    currentPageIndex = widget.getCurrentPageIndex();
  }

  @override
  void dispose() {
    widget.transformationController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final pageIndex = widget.getCurrentPageIndex();
    if (pageIndex == currentPageIndex || !mounted) return;
    setState(() => currentPageIndex = pageIndex);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);

    return Material(
      color: colorScheme.surfaceContainerLow,
      elevation: 3,
      child: SizedBox(
        width: EditorPagePanel.width,
        child: Column(
          children: [
            Padding(
              padding: const .fromLTRB(8, 8, 8, 0),
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: .compact,
                  tapTargetSize: .shrinkWrap,
                ),
                segments: [
                  ButtonSegment(
                    value: false,
                    tooltip: t.editor.pages,
                    icon: const Icon(Icons.auto_stories_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: true,
                    tooltip: t.editor.bookmarks.contents,
                    icon: const Icon(Icons.bookmarks_outlined, size: 18),
                  ),
                ],
                selected: {_showContents},
                onSelectionChanged: (selected) =>
                    setState(() => _showContents = selected.single),
              ),
            ),
            Expanded(
              child: _showContents
                  ? _buildContents(context)
                  : _buildThumbnails(context),
            ),
          ],
        ),
      ),
    );
  }

  /// The bookmarked pages, as a table of contents.
  Widget _buildContents(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);
    final pages = widget.coreInfo.pages;
    final bookmarked = [
      for (int i = 0; i < pages.length; i++)
        if (pages[i].bookmark != null) i,
    ];
    if (bookmarked.isEmpty) {
      return Padding(
        padding: const .all(12),
        child: Text(
          t.editor.bookmarks.empty,
          textAlign: .center,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView(
      padding: const .symmetric(vertical: 8),
      children: [
        for (final pageIndex in bookmarked)
          InkWell(
            onTap: () {
              widget.onPageTap(pageIndex);
              setState(() => currentPageIndex = pageIndex);
            },
            onLongPress: () => widget.onEditBookmark(pageIndex),
            child: Padding(
              padding: const .fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Icon(Icons.bookmark, size: 16, color: colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      children: [
                        Text(
                          pages[pageIndex].bookmark!.isEmpty
                              ? t.editor.bookmarks.page(n: pageIndex + 1)
                              : pages[pageIndex].bookmark!,
                          maxLines: 2,
                          overflow: .ellipsis,
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: pageIndex == currentPageIndex
                                ? .bold
                                : null,
                          ),
                        ),
                        Text(
                          '${pageIndex + 1}',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: .compact,
                    iconSize: 16,
                    tooltip: t.editor.bookmarks.edit,
                    onPressed: () => widget.onEditBookmark(pageIndex),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildThumbnails(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final pages = widget.coreInfo.pages;
    return ListView.builder(
      padding: const .symmetric(vertical: 8),
      itemCount: pages.length,
      itemBuilder: (context, pageIndex) {
        final selected = pageIndex == currentPageIndex;
        return InkWell(
          onTap: () {
            widget.onPageTap(pageIndex);
            setState(() => currentPageIndex = pageIndex);
          },
          child: Padding(
            padding: const .symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                DecoratedBox(
                  position: .foreground,
                  decoration: BoxDecoration(
                    border: .all(
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.outlineVariant,
                      width: selected ? 2.5 : 1,
                    ),
                    borderRadius: .circular(4),
                  ),
                  child: ClipRRect(
                    borderRadius: .circular(4),
                    // previews are for looking at, not for editing
                    child: IgnorePointer(
                      child: FittedBox(
                        child: CanvasPreview(
                          pageIndex: pageIndex,
                          height: null,
                          coreInfo: widget.coreInfo,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: .center,
                  children: [
                    if (pages[pageIndex].bookmark != null)
                      Icon(
                        Icons.bookmark,
                        size: 14,
                        color: colorScheme.primary,
                      ),
                    Text(
                      '${pageIndex + 1}',
                      style: TextTheme.of(context).labelMedium?.copyWith(
                        color: selected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        fontWeight: selected ? .bold : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
