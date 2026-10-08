import 'dart:io';

import 'dart:ui';

import 'package:bson/bson.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:sbn/tool_id.dart';

/// The web editor (`server/web`) writes operations in JavaScript.
/// `test/fixtures/web_ops.bson` holds some that it wrote, which the app
/// must understand like its own.
void main() {
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();

  test('operations written by the web editor', () {
    final bytes = File('test/fixtures/web_ops.bson').readAsBytesSync();
    final ops = (BsonCodec.deserialize(BsonBinary.from(bytes))['ops'] as List)
        .cast<Map<String, dynamic>>();

    final coreInfo = EditorCoreInfo(filePath: '/web');
    final pages = coreInfo.pages;
    void createPage(int pageIndex) {
      while (pageIndex >= pages.length - 1) {
        pages.add(EditorPage());
        coreInfo.assignPageIds();
      }
    }

    createPage(-1);
    final applier = NoteOpApplier(
      coreInfo: coreInfo,
      createPage: createPage,
      removeExcessPages: () {},
    );
    for (final op in ops) {
      applier.apply(op);
    }

    final strokes = pages.first.strokes;
    expect(strokes.map((s) => s.id), containsAll(['webStroke1', 'webStroke2']));
    final circle = strokes.whereType<CircleStroke>().single;
    expect(circle.id, 'webCircle');
    expect(circle.center, const Offset(500, 600));
    expect(circle.radius, 80);
    final highlighter = strokes.firstWhere((s) => s.id == 'webStroke1');
    expect(highlighter.toolId, ToolId.highlighter);
    expect(highlighter.color.toARGB32(), 0x64ffeb3b);
    expect(highlighter.options.size, 50);
    expect(highlighter.pressureEnabled, isFalse);

    final pen = strokes.firstWhere((s) => s.id == 'webStroke2');
    // scaled by 2 around 10,20
    expect(pen.options.size, 10);
    final bounds = pen.lowQualityPath.getBounds();
    expect(bounds.center.dx, closeTo(30, 6));
    expect(bounds.center.dy, closeTo(40, 6));
    expect(pages.first.bookmark, 'Web');

    final image = pages.first.images.single;
    expect(image.uid, 'webImage1');
    // moved by the update after it was added
    expect(image.dstRect, const Rect.fromLTWH(120, 200, 300, 150));

    expect(coreInfo.flashcards, isTrue);
    final study = pages.first.study!;
    expect(study.repetitions, 1);
    expect(study.intervalDays, 1);
    expect(study.due, DateTime.utc(2026, 10, 9));
  });
}
