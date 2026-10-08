import 'package:flutter/material.dart';

/// Draws a note as a closed notebook: a portrait cover with a spine.
///
/// The cover is either [color] with the note's [title] on a label,
/// or [preview] (the note's first page) if [color] is null.
class NotebookCover extends StatelessWidget {
  const new({
    super.key,
    required this.title,
    required this.color,
    required this.preview,
    this.selected = false,
    this.favorite = false,
  });

  final String title;
  final Color? color;
  final Widget preview;
  final bool selected;
  final bool favorite;

  /// The width divided by the height of a cover.
  static const aspectRatio = 0.74;

  static const _borderRadius = BorderRadius.horizontal(
    left: .circular(4),
    right: .circular(10),
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final color = this.color;

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: _borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 6,
              offset: const Offset(1, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: _borderRadius,
          child: Stack(
            fit: .expand,
            children: [
              if (color == null)
                preview
              else
                ColoredBox(
                  color: color,
                  child: Align(
                    alignment: const Alignment(0, -0.45),
                    child: FractionallySizedBox(
                      widthFactor: 0.72,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: .circular(3),
                        ),
                        child: Padding(
                          padding: const .symmetric(horizontal: 6, vertical: 8),
                          child: Text(
                            title,
                            maxLines: 3,
                            overflow: .ellipsis,
                            textAlign: .center,
                            style: const TextStyle(
                              color: Color(0xFF222222),
                              fontSize: 12,
                              height: 1.2,
                              fontWeight: .w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // the spine
              const Align(
                alignment: .centerLeft,
                child: SizedBox(
                  width: 12,
                  height: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0x55000000),
                          Color(0x18000000),
                          Color(0x30000000),
                          Color(0x00000000),
                        ],
                        stops: [0, 0.55, 0.75, 1],
                      ),
                    ),
                  ),
                ),
              ),
              if (selected)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.18),
                    border: .all(color: colorScheme.primary, width: 3),
                    borderRadius: _borderRadius,
                  ),
                ),
              if (favorite)
                const Align(
                  alignment: .topRight,
                  child: Padding(
                    padding: .all(6),
                    child: Icon(
                      Icons.star_rounded,
                      size: 22,
                      color: Color(0xFFFFC83D),
                      shadows: [
                        Shadow(color: Color(0x88000000), blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              if (selected)
                Align(
                  alignment: .bottomRight,
                  child: Padding(
                    padding: const .all(6),
                    child: Icon(
                      Icons.check_circle,
                      size: 24,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
