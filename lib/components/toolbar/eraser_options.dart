import 'package:flutter/material.dart';
import 'package:saber/data/extensions/axis_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/i18n/strings.g.dart';

/// Lets the user choose how the eraser erases, and how big it is.
class EraserOptions extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final axis = stows.editorToolbarAlignment.value.axis.opposite;
    final colorScheme = ColorScheme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([stows.eraserPartial, stows.eraserSize]),
      builder: (context, _) => Padding(
        padding: const .all(8),
        child: Flex(
          direction: axis,
          mainAxisAlignment: .center,
          spacing: 16,
          children: [
            SegmentedButton<bool>(
              direction: axis,
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.content_cut, size: 18),
                  label: Text(t.editor.eraserOptions.partial),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.gesture, size: 18),
                  label: Text(t.editor.eraserOptions.wholeStroke),
                ),
              ],
              selected: {stows.eraserPartial.value},
              onSelectionChanged: (selected) =>
                  stows.eraserPartial.value = selected.single,
            ),
            Flex(
              direction: axis,
              mainAxisSize: .min,
              spacing: 4,
              children: [
                for (final size in Eraser.sizes)
                  IconButton(
                    tooltip: '${t.editor.penOptions.size} ${size.round()}',
                    isSelected: stows.eraserSize.value == size,
                    onPressed: () => stows.eraserSize.value = size,
                    style: IconButton.styleFrom(
                      backgroundColor: stows.eraserSize.value == size
                          ? colorScheme.secondary.withValues(alpha: 0.15)
                          : Colors.transparent,
                    ),
                    icon: Container(
                      width: 6 + size / 2,
                      height: 6 + size / 2,
                      decoration: BoxDecoration(
                        shape: .circle,
                        border: Border.all(
                          color: stows.eraserSize.value == size
                              ? colorScheme.secondary
                              : colorScheme.onSurface,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
