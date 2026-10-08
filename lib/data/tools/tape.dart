import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';

/// Draws tape over part of a page, which hides what's under it until the
/// tape is tapped, so that the user can quiz themselves.
class Tape extends Pen {
  new()
    : super(
        name: t.editor.pens.tape,
        sizeMin: 10,
        sizeMax: 80,
        sizeStep: 2,
        icon: tapeIcon,
        options: StrokeOptions(
          size: 28,
          thinning: 0,
          smoothing: 0.7,
          streamline: 0.7,
        ),
        pressureEnabled: false,
        color: defaultColor,
        toolId: .tape,
      );

  static const defaultColor = Color(0xFFF2B84B);
  static const tapeIcon = FontAwesomeIcons.tape;

  static final currentTape = Tape();

  /// Returns the tape among [strokes] at [position], if there's one,
  /// the topmost first.
  static Stroke? tapeAt(Offset position, List<Stroke> strokes) {
    for (final stroke in strokes.reversed) {
      if (stroke.toolId != .tape) continue;
      if (stroke.lowQualityPath.contains(position)) return stroke;
    }
    return null;
  }
}
