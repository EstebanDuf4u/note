import 'dart:convert';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/prefs.dart';
import 'package:sbn/has_size.dart';

/// Handwriting that the user saved to add again to any note,
/// like a sticker: a diagram, a signature, a heading...
class NoteElement {
  const new({required this.id, required this.size, required this.strokes});

  factory fromJson(Map<String, dynamic> json) => NoteElement(
    id: json['id'] as String,
    size: Size((json['w'] as num).toDouble(), (json['h'] as num).toDouble()),
    // strokes hold binary data, so they're kept as base64 encoded bson
    strokes: [
      for (final stroke
          in BsonCodec.deserialize(
                BsonBinary.from(base64Decode(json['b'] as String)),
              )['s']
              as List)
        Map<String, dynamic>.from(stroke as Map),
    ],
  );

  final String id;

  /// The size of the box around the strokes.
  final Size size;

  /// The strokes, as saved in a note, with the box's top left corner at 0,0.
  final List<Map<String, dynamic>> strokes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'w': size.width,
    'h': size.height,
    'b': base64Encode(BsonCodec.serialize({'s': strokes}).byteList),
  };

  /// Returns new strokes for [page] like those of this element,
  /// with the top left corner of the element at [topLeft].
  List<Stroke> createStrokes({
    required HasSize page,
    required int pageIndex,
    Offset topLeft = .zero,
  }) => [
    for (final json in strokes)
      Stroke.fromJson(
          {...json, 'i': pageIndex},
          fileVersion: EditorCoreInfo.sbnVersion,
          pageIndex: pageIndex,
          page: page,
        )
        ..id = newId()
        ..shift(topLeft),
  ];
}

/// The elements that the user saved. See [NoteElement].
abstract final class ElementLibrary {
  /// Elements beyond this many replace the oldest ones.
  static const maxElements = 60;

  static List<NoteElement> get all {
    try {
      return [
        for (final json in jsonDecode(stows.savedElements.value) as List)
          NoteElement.fromJson(json as Map<String, dynamic>),
      ];
    } catch (e) {
      return [];
    }
  }

  static void _save(List<NoteElement> elements) => stows.savedElements.value =
      jsonEncode([for (final element in elements) element.toJson()]);

  /// Saves [strokes] as a new element, and returns it,
  /// or null if there's nothing to save.
  static NoteElement? add(List<Stroke> strokes) {
    if (strokes.isEmpty) return null;
    var bounds = strokes.first.lowQualityPath.getBounds();
    for (final stroke in strokes.skip(1)) {
      bounds = bounds.expandToInclude(stroke.lowQualityPath.getBounds());
    }
    final element = NoteElement(
      id: newId(),
      size: bounds.size,
      strokes: [
        for (final stroke in strokes)
          (stroke.copy()..shift(-bounds.topLeft)).toJson()
            ..remove('id')
            ..remove('i'),
      ],
    );
    final elements = [element, ...all];
    if (elements.length > maxElements) elements.removeLast();
    _save(elements);
    return element;
  }

  static void remove(String id) => _save([
    for (final element in all)
      if (element.id != id) element,
  ]);
}
