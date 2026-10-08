import 'dart:ui';

import 'package:saber/components/canvas/_stroke.dart';

import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:sbn/tool_id.dart';

double square(double x) => x * x;
double sqrDistanceBetween(Offset p1, Offset p2) =>
    square(p1.dx - p2.dx) + square(p1.dy - p2.dy);

class Eraser extends Tool {
  /// The radius of the eraser.
  double get size => _size ?? stows.eraserSize.value;
  double get sqrSize => square(size);
  final double? _size;

  /// Whether only the parts of strokes under the eraser are erased,
  /// rather than every stroke that the eraser touches.
  bool get partial => _partial ?? stows.eraserPartial.value;
  final bool? _partial;

  /// The strokes from before this drag that have been erased (or cut).
  List<Stroke> _erased = [];

  /// The pieces of cut strokes that are still on the page.
  List<Stroke> _pieces = [];

  /// The [size] and [partial] are the user's preferences unless given.
  new({this._size, this._partial});

  /// The sizes that the user can pick from.
  static const sizes = [5.0, 10.0, 20.0, 40.0];

  @override
  ToolId get toolId => .eraser;

  /// Returns any [strokes] that are close to the given [eraserPos].
  List<Stroke> checkForOverlappingStrokes(
    Offset eraserPos,
    List<Stroke> strokes,
  ) {
    final List<Stroke> overlapping = [];
    for (int i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      if (_shouldStrokeBeErased(eraserPos, stroke, sqrSize)) {
        overlapping.add(stroke);
        _erased.add(stroke);
      }
    }
    return overlapping;
  }

  /// Erases what's under the eraser at [eraserPos] from [strokes], cutting
  /// strokes if [partial], and returns whether [strokes] changed.
  bool erase(Offset eraserPos, List<Stroke> strokes) {
    if (!partial) {
      final overlapping = checkForOverlappingStrokes(eraserPos, strokes);
      strokes.removeWhere(overlapping.contains);
      return overlapping.isNotEmpty;
    }

    var changed = false;
    for (int i = strokes.length - 1; i >= 0; --i) {
      final stroke = strokes[i];
      final pieces = stroke.erasedAround(eraserPos, size);
      if (pieces == null) continue;
      changed = true;
      // the pieces take the stroke's place, so they stay in the same layer
      strokes.replaceRange(i, i + 1, pieces);
      if (!_pieces.remove(stroke)) _erased.add(stroke);
      _pieces.addAll(pieces);
    }
    return changed;
  }

  /// Returns the strokes that have been erased during this drag,
  /// and the pieces of them that are left, which replace them.
  ({List<Stroke> erased, List<Stroke> pieces}) onDragEnd() {
    final result = (erased: _erased, pieces: _pieces);
    _erased = [];
    _pieces = [];
    return result;
  }

  static bool _shouldStrokeBeErased(
    Offset eraserPos,
    Stroke stroke,
    double sqrSize,
  ) {
    if (stroke.length <= 3) {
      if (stroke.lowQualityPath.contains(eraserPos)) return true;
    }

    /// skip checking every few vertices for performance
    final int verticesToSkip = switch (stroke.lowQualityPolygon.length) {
      < 100 => 0,
      < 1000 => 1,
      _ => 2,
    };

    for (
      int i = 0;
      i < stroke.lowQualityPolygon.length;
      i += verticesToSkip + 1
    ) {
      final Offset strokeVertex = stroke.lowQualityPolygon[i];
      if (sqrDistanceBetween(strokeVertex, eraserPos) <= sqrSize) return true;
    }
    return false;
  }
}
