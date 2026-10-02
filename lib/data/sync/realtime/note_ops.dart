import 'dart:ui';

import 'package:fixnum/fixnum.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/editor/page.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// A change to a note, in a form that can be sent to other devices.
///
/// Operations address strokes and pages by id (never by index) so that
/// they can be applied on a device whose note has diverged slightly.
/// They're plain maps so they can be saved in the note and sent as BSON.
typedef NoteOp = Map<String, dynamic>;

/// Bson decodes large ints as [Int64], so use this to read any int.
int opInt(dynamic value) => switch (value) {
  (final int value) => value,
  (final Int64 value) => value.toInt(),
  (final num value) => value.toInt(),
  _ => throw ArgumentError('Not an int: (${value.runtimeType}) $value'),
};

abstract final class NoteOps {
  static const addStrokeType = 'as';
  static const removeStrokesType = 'rs';
  static const moveStrokesType = 'ms';
  static const colorStrokesType = 'cs';
  static const insertPageType = 'ip';
  static const deletePageType = 'dp';
  static const backgroundPatternType = 'bg';

  static NoteOp addStroke(String pageId, Stroke stroke) => {
    't': addStrokeType,
    'pg': pageId,
    // the page index is local to each device
    's': stroke.toJson()..remove('i'),
  };

  static NoteOp removeStrokes(Iterable<Stroke> strokes) => {
    't': removeStrokesType,
    'ids': [for (final stroke in strokes) stroke.id],
  };

  static NoteOp moveStrokes(Iterable<Stroke> strokes, Offset offset) => {
    't': moveStrokesType,
    'ids': [for (final stroke in strokes) stroke.id],
    'dx': offset.dx,
    'dy': offset.dy,
  };

  static NoteOp colorStrokes(Map<Stroke, Color> colors) => {
    't': colorStrokesType,
    'c': {
      for (final MapEntry(key: stroke, value: color) in colors.entries)
        stroke.id: color.toARGB32(),
    },
  };

  static NoteOp insertPage(EditorPage page, {required String? afterPageId}) => {
    't': insertPageType,
    'id': page.id,
    'after': afterPageId,
    'w': page.size.width,
    'h': page.size.height,
  };

  static NoteOp deletePage(EditorPage page) => {
    't': deletePageType,
    'id': page.id,
  };

  static NoteOp backgroundPattern(CanvasBackgroundPattern pattern) => {
    't': backgroundPatternType,
    'p': pattern.name,
  };

  /// Returns the operations that describe [item],
  /// or that describe undoing [item] if [inverse] is true.
  ///
  /// Call this after the change has been applied to [coreInfo].
  ///
  /// Images and text aren't synced in realtime yet.
  static List<NoteOp> fromHistoryItem(
    EditorHistoryItem item,
    EditorCoreInfo coreInfo, {
    required bool inverse,
  }) {
    List<NoteOp> add() => [
      for (final stroke in item.strokes)
        addStroke(_pageOfStroke(stroke, coreInfo).id, stroke),
    ];
    List<NoteOp> remove() => [
      if (item.strokes.isNotEmpty) removeStrokes(item.strokes),
    ];
    List<NoteOp> insertPageOps() {
      final page = item.page!;
      final index = coreInfo.pages.indexOf(page);
      return [
        insertPage(
          page,
          afterPageId: index > 0 ? coreInfo.pages[index - 1].id : null,
        ),
        for (final stroke in page.strokes) addStroke(page.id, stroke),
      ];
    }

    switch (item.type) {
      case .draw:
        return inverse ? remove() : add();
      case .erase:
        return inverse ? add() : remove();
      case .insertPage:
        return inverse ? [deletePage(item.page!)] : insertPageOps();
      case .deletePage:
        return inverse ? insertPageOps() : [deletePage(item.page!)];
      case .move:
        if (item.strokes.isEmpty) return const [];
        final offset = Offset(item.offset!.left, item.offset!.top);
        return [moveStrokes(item.strokes, inverse ? -offset : offset)];
      case .changeColor:
        return [
          colorStrokes({
            for (final MapEntry(key: stroke, value: change)
                in item.colorChange!.entries)
              stroke: inverse ? change.previous : change.current,
          }),
        ];
      case .backgroundPattern:
        final change = item.backgroundPatternChange!;
        return [backgroundPattern(inverse ? change.previous : change.current)];
      case .quillChange:
      case .quillUndoneChange:
        return const [];
    }
  }

  static EditorPage _pageOfStroke(Stroke stroke, EditorCoreInfo coreInfo) {
    final pages = coreInfo.pages;
    if (stroke.pageIndex < pages.length &&
        pages[stroke.pageIndex].strokes.contains(stroke)) {
      return pages[stroke.pageIndex];
    }
    return pages.firstWhere(
      (page) => page.strokes.contains(stroke),
      orElse: () => pages[stroke.pageIndex.clamp(0, pages.length - 1)],
    );
  }

  /// Returns the operations that recreate the whole of [coreInfo],
  /// skipping any strokes whose id is in [knownStrokeIds].
  static List<NoteOp> snapshot(
    EditorCoreInfo coreInfo, {
    Set<String> knownStrokeIds = const {},
  }) {
    final ops = <NoteOp>[backgroundPattern(coreInfo.backgroundPattern)];
    String? previousPageId;
    for (final page in coreInfo.pages) {
      // The blank page at the end is recreated by each device
      if (page == coreInfo.pages.last && page.isEmpty) break;
      ops.add(insertPage(page, afterPageId: previousPageId));
      for (final stroke in page.strokes) {
        if (knownStrokeIds.contains(stroke.id)) continue;
        ops.add(addStroke(page.id, stroke));
      }
      previousPageId = page.id;
    }
    return ops;
  }
}

/// Applies operations received from other devices to a note.
class NoteOpApplier {
  new({
    required this.coreInfo,
    required this.createPage,
    required this.removeExcessPages,
    this.onPageInserted,
  });

  static final log = Logger('NoteOpApplier');

  /// How many automatically appended pages we'll create
  /// to reach a page that another device drew on.
  static const _maxDerivedPages = 16;

  EditorCoreInfo coreInfo;

  /// Creates pages until the given page index exists, plus a blank page.
  final void Function(int pageIndex) createPage;

  /// Removes the blank pages at the end of the note, except one.
  final void Function() removeExcessPages;

  final void Function(EditorPage page, int pageIndex)? onPageInserted;

  /// The ids of strokes that have been removed, so that a stroke isn't
  /// re-added if its removal is applied before a repeat of its addition.
  final removedStrokeIds = <String>{};

  /// The ids of every stroke added by an applied operation.
  final addedStrokeIds = <String>{};

  /// Applies [op] to [coreInfo].
  ///
  /// [pendingLocalOps] are the local operations that haven't been
  /// acknowledged by the server yet. They'll be ordered after [op],
  /// so they take priority when both set the same value.
  ///
  /// [isUnsent] should return whether a local stroke has yet to be sent to
  /// the server, other than those added by [pendingLocalOps].
  void apply(
    NoteOp op, {
    Iterable<NoteOp> pendingLocalOps = const [],
    bool Function(Stroke stroke)? isUnsent,
  }) {
    switch (op['t']) {
      case NoteOps.addStrokeType:
        final pendingStrokeIds = <String>{
          for (final pending in pendingLocalOps)
            if (pending['t'] == NoteOps.addStrokeType)
              (pending['s'] as Map)['id'] as String,
        };
        _addStroke(
          op,
          isAfter: (stroke) =>
              pendingStrokeIds.contains(stroke.id) ||
              (isUnsent?.call(stroke) ?? false),
        );
      case NoteOps.removeStrokesType:
        for (final String id in (op['ids'] as List).cast()) {
          removedStrokeIds.add(id);
          final (page, stroke) = _findStroke(id);
          page?.strokes.remove(stroke);
        }
        removeExcessPages();
      case NoteOps.moveStrokesType:
        final offset = Offset(
          (op['dx'] as num).toDouble(),
          (op['dy'] as num).toDouble(),
        );
        for (final String id in (op['ids'] as List).cast()) {
          _findStroke(id).$2?.shift(offset);
        }
      case NoteOps.colorStrokesType:
        final overridden = <String>{
          for (final pending in pendingLocalOps)
            if (pending['t'] == NoteOps.colorStrokesType)
              ...(pending['c'] as Map).keys.cast<String>(),
        };
        for (final MapEntry(key: id, value: color)
            in (op['c'] as Map).entries) {
          if (overridden.contains(id)) continue;
          _findStroke(id as String).$2?.color = Color(opInt(color));
        }
      case NoteOps.insertPageType:
        _insertPage(op);
      case NoteOps.deletePageType:
        final index = _indexOfPage(op['id'] as String);
        if (index < 0) return;
        coreInfo.pages.removeAt(index).dispose();
        _updatePageIndices(from: index);
        _ensureBlankLastPage();
      case NoteOps.backgroundPatternType:
        final overridden = pendingLocalOps.any(
          (pending) => pending['t'] == NoteOps.backgroundPatternType,
        );
        if (overridden) return;
        coreInfo.backgroundPattern = .fromName(op['p'] as String?);
      default:
        // probably from a newer version of the app
        log.warning('Unknown operation type: ${op['t']}');
    }
  }

  /// Adds the stroke in [op] to its page.
  ///
  /// Strokes are layered in the order that the server received them,
  /// so the new stroke goes below the local strokes for which [isAfter]
  /// returns true, since they'll reach the server later.
  void _addStroke(NoteOp op, {required bool Function(Stroke stroke) isAfter}) {
    final json = Map<String, dynamic>.from(op['s'] as Map);
    final id = json['id'] as String;
    addedStrokeIds.add(id);
    if (removedStrokeIds.contains(id)) return;
    if (_findStroke(id).$2 != null) return;

    final pageIndex = _materializePage(op['pg'] as String);
    final page = coreInfo.pages[pageIndex];
    final stroke = Stroke.fromJson(
      json,
      fileVersion: EditorCoreInfo.sbnVersion,
      pageIndex: pageIndex,
      page: page,
    );
    page.insertStroke(stroke);

    final strokes = page.strokes;
    int index = strokes.indexOf(stroke);
    while (index > 0) {
      final below = strokes[index - 1];
      final sameLayer =
          below.toolId == stroke.toolId &&
          (stroke.toolId != .highlighter || below.color == stroke.color);
      if (!sameLayer || !isAfter(below)) break;
      strokes[index] = below;
      strokes[index - 1] = stroke;
      index--;
    }

    createPage(pageIndex);
  }

  void _insertPage(NoteOp op) {
    final id = op['id'] as String;
    if (_indexOfPage(id) >= 0) return;

    final after = op['after'] as String?;
    final int index;
    if (after == null) {
      index = 0;
    } else {
      final afterIndex = _indexOfPage(after);
      index = afterIndex < 0 ? coreInfo.pages.length : afterIndex + 1;
    }

    final page = EditorPage(
      id: id,
      width: (op['w'] as num?)?.toDouble(),
      height: (op['h'] as num?)?.toDouble(),
    );
    coreInfo.pages.insert(index, page);
    _updatePageIndices(from: index);
    onPageInserted?.call(page, index);
    _ensureBlankLastPage();
  }

  /// Returns the index of the page with id [pageId],
  /// creating the page if it doesn't exist yet.
  int _materializePage(String pageId) {
    final existing = _indexOfPage(pageId);
    if (existing >= 0) return existing;

    // The page is most likely one that the other device
    // automatically appended to the end of its note.
    var derivedId = coreInfo.pages.isEmpty
        ? firstPageId
        : derivePageId(coreInfo.pages.last.id);
    for (int i = 0; i < _maxDerivedPages; ++i) {
      if (derivedId == pageId) {
        createPage(coreInfo.pages.length + i);
        final index = _indexOfPage(pageId);
        if (index >= 0) return index;
        break;
      }
      derivedId = derivePageId(derivedId);
    }

    // Otherwise the devices disagree on the id of the blank last page,
    // e.g. because a page was inserted before it on one of them.
    if (coreInfo.pages.isNotEmpty && coreInfo.pages.last.isEmpty) {
      coreInfo.pages.last.id = pageId;
      return coreInfo.pages.length - 1;
    }

    log.warning('Stroke added to unknown page $pageId, appending the page');
    final page = EditorPage(id: pageId);
    coreInfo.pages.add(page);
    onPageInserted?.call(page, coreInfo.pages.length - 1);
    return coreInfo.pages.length - 1;
  }

  void _ensureBlankLastPage() {
    if (coreInfo.pages.isEmpty || coreInfo.pages.last.isNotEmpty) {
      createPage(coreInfo.pages.length - 1);
    }
  }

  void _updatePageIndices({required int from}) {
    for (int i = from; i < coreInfo.pages.length; ++i) {
      coreInfo.pages[i].updatePageIndex(i);
    }
  }

  int _indexOfPage(String pageId) =>
      coreInfo.pages.indexWhere((page) => page.id == pageId);

  (EditorPage?, Stroke?) _findStroke(String id) {
    for (final page in coreInfo.pages) {
      for (final stroke in page.strokes) {
        if (stroke.id == id) return (page, stroke);
      }
    }
    return (null, null);
  }
}
