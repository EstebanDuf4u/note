import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:sbn/has_size.dart';

final _options = StrokeOptions(
  size: 1, // small size so we have more precision in test
);
const _eraserPos = Offset(50, 50);

void main() {
  test('Test that the eraser tool erases the correct strokes', () {
    final eraser = Eraser(size: 10, partial: false);

    final List<Stroke> strokesToErase = [
      // center
      _strokeWithPoint(_eraserPos),

      // 1 size downwards from center
      _strokeWithPoint(_eraserPos + const Offset(0, 1) * eraser.size),

      // 1 size right from center
      _strokeWithPoint(_eraserPos + const Offset(1, 0) * eraser.size),

      // 1 size diagonally from center
      _strokeWithPoint(_eraserPos + const Offset(1, 1) * sqrt(eraser.size)),

      // 0.5 sizes right from center
      _strokeWithPoint(_eraserPos + const Offset(0.5, 0) * eraser.size),

      // straight line that passes through center
      _strokeWithPoint(_eraserPos + const Offset(-20, -20) * eraser.size)
        ..addPoint(_eraserPos + const Offset(20, 20) * eraser.size)
        ..addPoint(_eraserPos + const Offset(20, 20) * eraser.size),
    ];

    final List<Stroke> strokesToKeep = [
      // > 1 size downwards from center
      _strokeWithPoint(_eraserPos + const Offset(0, 1.1) * eraser.size),

      // > 1 size right from center
      _strokeWithPoint(_eraserPos + const Offset(1.1, 0) * eraser.size),

      // > 1 size diagonally from center
      _strokeWithPoint(_eraserPos + const Offset(1, 1) * eraser.size),

      // 2 sizes right from center
      _strokeWithPoint(_eraserPos + const Offset(2, 0) * eraser.size),
    ];

    final strokes = <Stroke>[...strokesToErase, ...strokesToKeep];
    final List<Stroke> erased = eraser.checkForOverlappingStrokes(
      _eraserPos,
      strokes,
    );

    for (final stroke in strokesToErase) {
      expect(
        erased,
        contains(stroke),
        reason: 'Stroke should be erased: $stroke',
      );
    }

    for (final stroke in strokesToKeep) {
      expect(
        erased,
        isNot(contains(stroke)),
        reason: 'Stroke should not be erased: $stroke',
      );
    }

    final List<Stroke> erasedStrokes = eraser.onDragEnd().erased;
    expect(
      erasedStrokes.length,
      strokesToErase.length,
      reason: 'The correct number of strokes should have been erased',
    );
    expect(
      erasedStrokes,
      everyElement(strokesToErase.contains),
      reason: 'The correct strokes should have been erased',
    );
  });

  group('Partial eraser', () {
    Stroke line(Offset from, Offset to) => _strokeWithPoint(from)
      ..addPoint(Offset.lerp(from, to, 0.5)!)
      ..addPoint(to);

    test('cuts a line in two around the eraser', () {
      final eraser = Eraser(size: 10, partial: true);
      // the points are far apart, so the eraser falls between two of them
      final stroke = line(const Offset(0, 50), const Offset(100, 50))
        ..addPoint(const Offset(100, 50));
      final strokes = [stroke];
      expect(eraser.erase(const Offset(30, 50), strokes), isTrue);

      expect(strokes, hasLength(2));
      expect(strokes, isNot(contains(stroke)));
      final left = strokes[0].lowQualityPath.getBounds();
      final right = strokes[1].lowQualityPath.getBounds();
      expect(left.right, lessThan(30 - 10 + 1));
      expect(right.left, greaterThan(30 + 10 - 1));
      expect(left.left, lessThan(1));
      expect(right.right, greaterThan(99));
      // each piece is a new stroke
      expect(strokes.map((s) => s.id).toSet(), hasLength(2));
      expect(strokes.map((s) => s.id), isNot(contains(stroke.id)));

      // cutting a piece again replaces the piece, not the original
      expect(eraser.erase(const Offset(70, 50), strokes), isTrue);
      expect(strokes, hasLength(3));
      final (:erased, :pieces) = eraser.onDragEnd();
      expect(erased, [stroke]);
      expect(pieces, unorderedEquals(strokes));
    });

    test('leaves strokes that it does not touch', () {
      final eraser = Eraser(size: 10, partial: true);
      final strokes = [line(const Offset(0, 0), const Offset(100, 0))];
      expect(eraser.erase(const Offset(50, 30), strokes), isFalse);
      expect(strokes, hasLength(1));
      expect(eraser.onDragEnd().erased, isEmpty);
    });

    test('erases the end of a stroke without leaving a dot', () {
      final eraser = Eraser(size: 10, partial: true);
      final stroke = line(const Offset(0, 0), const Offset(100, 0));
      final strokes = [stroke];
      eraser.erase(const Offset(100, 0), strokes);
      expect(strokes, hasLength(1));
      expect(strokes.single.lowQualityPath.getBounds().right, lessThan(91));

      // and a small stroke is erased whole
      final dot = _strokeWithPoint(const Offset(200, 200));
      final dots = [dot];
      eraser.erase(const Offset(201, 200), dots);
      expect(dots, isEmpty);
    });
  });
}

Stroke _strokeWithPoint(Offset point) => Stroke(
  color: Stroke.defaultColor,
  pressureEnabled: Stroke.defaultPressureEnabled,
  options: _options,
  pageIndex: 0,
  page: const HasSize(Size(100, 100)),
  toolId: .fountainPen,
)..addPoint(point);
