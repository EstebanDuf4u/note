import 'package:flutter/material.dart';

/// Where another person who has the note open is writing.
class RemoteCursor {
  const new({
    required this.user,
    required this.position,
    required this.color,
    required this.down,
  });

  /// The name of their account.
  final String user;

  /// Where they are on the page, in page coordinates.
  final Offset position;

  final Color color;

  /// Whether their pen is on the page.
  final bool down;

  /// The colors that collaborators are told apart by.
  static const colors = [
    Color(0xFFE5484D),
    Color(0xFF30A46C),
    Color(0xFF0090FF),
    Color(0xFFF76B15),
    Color(0xFF8E4EC6),
    Color(0xFF12A594),
    Color(0xFFD6409F),
    Color(0xFF978365),
  ];

  /// Returns the color of the device [clientId], the same on every device.
  static Color colorOf(String clientId) {
    var hash = 0;
    for (final unit in clientId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return colors[hash % colors.length];
  }
}

/// Shows where the other people who have the note open are on a page.
class RemoteCursors extends StatelessWidget {
  const new({super.key, required this.cursors, required this.scale});

  final List<RemoteCursor> cursors;

  /// How zoomed in the page is, so that the labels keep the same size.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final inverseScale = 1 / scale.clamp(0.2, 10);
    return IgnorePointer(
      child: Stack(
        clipBehavior: .none,
        children: [
          for (final cursor in cursors)
            AnimatedPositioned(
              key: ValueKey(cursor.user + cursor.color.toARGB32().toString()),
              duration: const Duration(milliseconds: 90),
              left: cursor.position.dx,
              top: cursor.position.dy,
              child: Transform.scale(
                scale: inverseScale,
                alignment: .topLeft,
                child: _Cursor(cursor: cursor),
              ),
            ),
        ],
      ),
    );
  }
}

class _Cursor extends StatelessWidget {
  const new({required this.cursor});

  final RemoteCursor cursor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: .start,
      mainAxisSize: .min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: cursor.down ? 12 : 10,
          height: cursor.down ? 12 : 10,
          transform: Matrix4.translationValues(-6, -6, 0),
          decoration: BoxDecoration(
            shape: .circle,
            color: cursor.color,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Color(0x40000000), blurRadius: 4),
            ],
          ),
        ),
        Container(
          margin: const .only(left: 4, top: 2),
          padding: const .symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: cursor.color,
            borderRadius: .circular(8),
          ),
          child: Text(
            cursor.user,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: .w600,
            ),
          ),
        ),
      ],
    );
  }
}
