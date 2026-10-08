import 'package:flutter/material.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/data/editor/editor_core_info.dart';

/// A column of page thumbnails at the side of the editor,
/// to see where you are in the note and jump to another page.
class EditorPagePanel extends StatefulWidget {
  const new({
    super.key,
    required this.coreInfo,
    required this.transformationController,
    required this.getCurrentPageIndex,
    required this.onPageTap,
  });

  final EditorCoreInfo coreInfo;

  /// Changes when the user scrolls the note.
  final TransformationController transformationController;
  final int Function() getCurrentPageIndex;
  final void Function(int pageIndex) onPageTap;

  static const width = 136.0;

  @override
  State<EditorPagePanel> createState() => _EditorPagePanelState();
}

class _EditorPagePanelState extends State<EditorPagePanel> {
  late int currentPageIndex = widget.getCurrentPageIndex();

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
    final pages = widget.coreInfo.pages;

    return Material(
      color: colorScheme.surfaceContainerLow,
      elevation: 3,
      child: SizedBox(
        width: EditorPagePanel.width,
        child: ListView.builder(
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
              ),
            );
          },
        ),
      ),
    );
  }
}
