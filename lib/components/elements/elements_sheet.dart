import 'package:flutter/material.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/elements/element_library.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:sbn/has_size.dart';

/// Shows the elements that the user saved, to add one to the note.
class ElementsSheet extends StatelessWidget {
  const new({super.key, required this.onPick});

  final void Function(NoteElement element) onPick;

  static Future<void> show(
    BuildContext context,
    void Function(NoteElement element) onPick,
  ) => showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => ElementsSheet(
      onPick: (element) {
        Navigator.pop(context);
        onPick(element);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);
    return ValueListenableBuilder(
      valueListenable: stows.savedElements,
      builder: (context, _, _) {
        final elements = ElementLibrary.all;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: Column(
            crossAxisAlignment: .start,
            children: [
              Padding(
                padding: const .fromLTRB(24, 0, 24, 8),
                child: Text(t.elements.title, style: textTheme.titleLarge),
              ),
              Expanded(
                child: elements.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const .all(32),
                          child: Text(
                            t.elements.empty,
                            textAlign: .center,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const .fromLTRB(16, 0, 16, 16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 140,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                            ),
                        itemCount: elements.length,
                        itemBuilder: (context, index) {
                          final element = elements[index];
                          return Material(
                            color: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: .circular(12),
                              side: BorderSide(
                                color: colorScheme.outlineVariant,
                              ),
                            ),
                            clipBehavior: .antiAlias,
                            child: InkWell(
                              onTap: () => onPick(element),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Padding(
                                      padding: const .all(12),
                                      child: _ElementPreview(element: element),
                                    ),
                                  ),
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: IconButton(
                                      tooltip: t.elements.delete,
                                      visualDensity: .compact,
                                      iconSize: 16,
                                      color: Colors.black54,
                                      onPressed: () =>
                                          ElementLibrary.remove(element.id),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ElementPreview extends StatelessWidget {
  const new({required this.element});

  final NoteElement element;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      child: SizedBox.fromSize(
        size: Size(
          element.size.width.clamp(1, double.infinity),
          element.size.height.clamp(1, double.infinity),
        ),
        child: CustomPaint(
          painter: _ElementPainter(
            element.createStrokes(page: HasSize(element.size), pageIndex: 0),
          ),
        ),
      ),
    );
  }
}

class _ElementPainter extends CustomPainter {
  const new(this.strokes);

  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      canvas.drawPath(stroke.highQualityPath, Paint()..color = stroke.color);
    }
  }

  @override
  bool shouldRepaint(_ElementPainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}
