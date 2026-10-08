import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/elements/element_library.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:sbn/has_size.dart';

void main() {
  FlavorConfig.setup();
  setUp(() => stows.savedElements.value = '[]');

  const page = HasSize(Size(1000, 1400));
  Stroke line(Offset from, Offset to) =>
      Stroke(
          color: Colors.red,
          pressureEnabled: false,
          options: StrokeOptions(size: 4),
          pageIndex: 0,
          page: page,
          toolId: .ballpointPen,
        )
        ..addPoint(from)
        ..addPoint(to);

  test('handwriting is saved as an element and added again elsewhere', () {
    final strokes = [
      line(const Offset(300, 200), const Offset(400, 260)),
      line(const Offset(320, 240), const Offset(380, 300)),
    ];
    final saved = ElementLibrary.add(strokes)!;
    // the element starts at 0,0
    expect(saved.size.width, closeTo(104, 6));
    expect(saved.size.height, closeTo(104, 6));

    final element = ElementLibrary.all.single;
    expect(element.id, saved.id);
    final added = element.createStrokes(
      page: page,
      pageIndex: 2,
      topLeft: const Offset(50, 50),
    );
    expect(added, hasLength(2));
    expect(added.first.color.toARGB32(), Colors.red.toARGB32());
    expect(added.first.pageIndex, 2);
    // new strokes, not the original ones
    expect(added.map((s) => s.id), isNot(contains(strokes.first.id)));
    final bounds = added.first.lowQualityPath.getBounds();
    expect(bounds.left, closeTo(50, 4));
    expect(bounds.top, closeTo(50, 4));

    ElementLibrary.remove(element.id);
    expect(ElementLibrary.all, isEmpty);
  });
}
