import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bson/bson.dart';
import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:flutter_quill/quill_delta.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flashcards/study_state.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// A change to a note, in a form that can be sent to other devices.
///
/// Operations address strokes, images and pages by id (never by index) so
/// that they can be applied on a device whose note has diverged slightly.
/// They're plain maps so they can be saved in the note and sent as BSON.
typedef NoteOp = Map<String, dynamic>;

/// Bson decodes large ints as [Int64], so use this to read any int.
int opInt(dynamic value) => switch (value) {
  (final int value) => value,
  (final Int64 value) => value.toInt(),
  (final num value) => value.toInt(),
  _ => throw ArgumentError('Not an int: (${value.runtimeType}) $value'),
};

/// The files that images are drawn from (a picture, an svg or a pdf),
/// which are sent to the other devices before the images that use them.
abstract final class NoteAssets {
  /// Assets are sent in pieces of this many bytes,
  /// so that a large pdf isn't a single huge message.
  static const chunkSize = 512 * 1024;

  static final _hashesOfBytes = Expando<String>();
  static final _hashesOfFiles = <String, String>{};

  static String _hash(List<int> bytes) =>
      base64Url.encode(sha256.convert(bytes).bytes);

  /// Returns the contents of [source], which is an [EditorImage.assetSource].
  static Uint8List bytesOf(Object source) => switch (source) {
    (final Uint8List bytes) => bytes,
    (final List<int> bytes) => Uint8List.fromList(bytes),
    (final String string) => utf8.encode(string),
    (final File file) => file.readAsBytesSync(),
    _ => throw ArgumentError.value(source, 'source', 'Not an asset'),
  };

  static int lengthOf(Object source) => switch (source) {
    (final List<int> bytes) => bytes.length,
    (final File file) => file.lengthSync(),
    _ => bytesOf(source).length,
  };

  /// Returns an id for the contents of [source]
  /// that every device gives to the same contents.
  static String hashOf(Object source) {
    switch (source) {
      case (final Uint8List bytes):
        return _hashesOfBytes[bytes] ??= _hash(bytes);
      case (final File file):
        // a note's asset files are rewritten when the note is saved
        final stat = file.statSync();
        final key =
            '${file.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
        return _hashesOfFiles[key] ??= _hash(file.readAsBytesSync());
      default:
        return _hash(bytesOf(source));
    }
  }

  /// Whether [a] and [b] are known to be the same asset without reading them.
  static bool isSame(Object a, Object b) =>
      identical(a, b) ||
      (a is File && b is File && a.path == b.path) ||
      (a is String && b is String && a == b);
}

abstract final class NoteOps {
  static const addStrokeType = 'as';
  static const removeStrokesType = 'rs';
  static const moveStrokesType = 'ms';
  static const colorStrokesType = 'cs';
  static const insertPageType = 'ip';
  static const deletePageType = 'dp';
  static const movePageType = 'mp';
  static const backgroundPatternType = 'bg';
  static const assetChunkType = 'ac';
  static const addImageType = 'ai';
  static const removeImagesType = 'ri';
  static const updateImageType = 'ui';
  static const textType = 'qt';
  static const textDeltaType = 'qd';
  static const flashcardsType = 'fl';
  static const studyType = 'fc';

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

  /// Moves [page] so that it follows the page with id [afterPageId],
  /// or to the start of the note if [afterPageId] is null.
  static NoteOp movePage(EditorPage page, {required String? afterPageId}) => {
    't': movePageType,
    'id': page.id,
    'after': afterPageId,
  };

  static NoteOp backgroundPattern(CanvasBackgroundPattern pattern) => {
    't': backgroundPatternType,
    'p': pattern.name,
  };

  /// Returns the operations that send the asset with id [hash].
  static List<NoteOp> asset(String hash, Uint8List bytes) {
    final count = max(1, (bytes.length / NoteAssets.chunkSize).ceil());
    return [
      for (int i = 0; i < count; ++i)
        {
          't': assetChunkType,
          'h': hash,
          'i': i,
          'n': count,
          'b': BsonBinary.from(
            Uint8List.sublistView(
              bytes,
              i * NoteAssets.chunkSize,
              min(bytes.length, (i + 1) * NoteAssets.chunkSize),
            ),
          ),
        },
    ];
  }

  /// Returns the operations that add [image] to [page],
  /// preceded by its asset if the other devices don't have it yet.
  ///
  /// [sentAssets] are the assets that earlier operations of the same change
  /// have sent. If [othersHaveNote] is true, the other devices are assumed to
  /// have the assets of the images that are already in the note.
  static List<NoteOp> addImage(
    EditorImage image,
    EditorPage page,
    EditorCoreInfo coreInfo, {
    required Set<String> sentAssets,
    bool othersHaveNote = true,
  }) {
    final source = image.assetSource;
    final hash = NoteAssets.hashOf(source);
    final isKnown =
        !sentAssets.add(hash) ||
        (othersHaveNote &&
            _imagesOf(coreInfo).any(
              (other) =>
                  !identical(other, image) &&
                  NoteAssets.isSame(other.assetSource, source),
            ));
    return [
      if (!isKnown) ...asset(hash, NoteAssets.bytesOf(source)),
      {
        't': addImageType,
        'pg': page.id,
        'bg': identical(page.backgroundImage, image),
        'h': hash,
        'n': NoteAssets.lengthOf(source),
        // the asset and page indices are local to each device
        'm': image.toJson(OrderedAssetCache())
          ..remove('a')
          ..remove('i')
          ..remove('id'),
      },
    ];
  }

  static NoteOp removeImages(Iterable<EditorImage> images) => {
    't': removeImagesType,
    'ids': [for (final image in images) image.uid],
  };

  /// Describes where and how [image] is shown now.
  static NoteOp updateImage(EditorImage image, EditorCoreInfo coreInfo) => {
    't': updateImageType,
    'id': image.uid,
    'bg': coreInfo.pages.any((page) => identical(page.backgroundImage, image)),
    'x': image.dstRect.left,
    'y': image.dstRect.top,
    'w': image.dstRect.width,
    'h': image.dstRect.height,
    'sx': image.srcRect.left,
    'sy': image.srcRect.top,
    'sw': image.srcRect.width,
    'sh': image.srcRect.height,
    'v': image.invertible,
    'f': image.backgroundFit.index,
  };

  /// Describes the whole text of [page], for when a note or a page is shared
  /// for the first time. Later changes are sent with [textChange].
  ///
  /// The server turns this into the change that leads to this text.
  static NoteOp text(EditorPage page) {
    final text = page.quill.controller.document.toDelta();
    page.syncedText = text;
    return {'t': textType, 'pg': page.id, 'q': text.toJson()};
  }

  /// Returns the operation that describes how the text of [page] has changed
  /// since its last operation, or null if it hasn't.
  ///
  /// [base] is the sequence number of the last operation that the text was
  /// up to date with. The server uses it to merge this change with those
  /// that other devices made to the same text at the same time.
  static NoteOp? textChange(EditorPage page, {required int base}) {
    final text = page.quill.controller.document.toDelta();
    final change = page.syncedText.diff(text);
    page.syncedText = text;
    if (change.isEmpty) return null;
    return {'t': textDeltaType, 'pg': page.id, 'd': change.toJson(), 'b': base};
  }

  /// Describes whether the note is a deck of flashcards.
  static NoteOp flashcards(EditorCoreInfo coreInfo) => {
    't': flashcardsType,
    'on': coreInfo.flashcards,
  };

  /// Describes how well the user knows [page] as a flashcard.
  static NoteOp study(EditorPage page) => {
    't': studyType,
    'pg': page.id,
    'c': page.study?.toJson(),
  };

  static Iterable<EditorImage> _imagesOf(EditorCoreInfo coreInfo) sync* {
    for (final page in coreInfo.pages) {
      if (page.backgroundImage case final image?) yield image;
      yield* page.images;
    }
  }

  static Iterable<EditorImage> _imagesOfPage(EditorPage page) => [
    ?page.backgroundImage,
    ...page.images,
  ];

  /// Returns the operations that describe [item],
  /// or that describe undoing [item] if [inverse] is true.
  ///
  /// Call this after the change has been applied to [coreInfo].
  ///
  /// [skipImages] are left out, e.g. because they haven't been sized yet.
  /// Text isn't part of the history: see [text].
  static List<NoteOp> fromHistoryItem(
    EditorHistoryItem item,
    EditorCoreInfo coreInfo, {
    required bool inverse,
    Set<EditorImage> skipImages = const {},
  }) {
    final sentAssets = <String>{};
    final images = [
      for (final image in item.images)
        if (!skipImages.contains(image)) image,
    ];

    List<NoteOp> add() => [
      for (final stroke in item.strokes)
        addStroke(_pageOfStroke(stroke, coreInfo).id, stroke),
      for (final image in images)
        ...addImage(
          image,
          _pageOfImage(image, coreInfo),
          coreInfo,
          sentAssets: sentAssets,
        ),
    ];
    List<NoteOp> remove() => [
      if (item.strokes.isNotEmpty) removeStrokes(item.strokes),
      if (images.isNotEmpty) removeImages(images),
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
        for (final image in _imagesOfPage(page))
          if (!skipImages.contains(image))
            ...addImage(image, page, coreInfo, sentAssets: sentAssets),
        if (!page.quill.controller.document.isEmpty()) text(page),
        if (page.study != null) study(page),
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
        final offset = Offset(item.offset!.left, item.offset!.top);
        return [
          if (item.strokes.isNotEmpty)
            moveStrokes(item.strokes, inverse ? -offset : offset),
          // an image can be resized too, so its new position is sent whole
          for (final image in images) updateImage(image, coreInfo),
        ];
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

  static EditorPage _pageOfImage(EditorImage image, EditorCoreInfo coreInfo) {
    final pages = coreInfo.pages;
    return pages.firstWhere(
      (page) => _imagesOfPage(page).any((other) => identical(other, image)),
      orElse: () => pages[image.pageIndex.clamp(0, pages.length - 1)],
    );
  }

  /// Returns the operations that recreate the whole of [coreInfo],
  /// skipping any strokes whose id is in [knownStrokeIds], and any images
  /// that are in [skipImages] or whose uid is in [knownImageIds].
  static List<NoteOp> snapshot(
    EditorCoreInfo coreInfo, {
    Set<String> knownStrokeIds = const {},
    Set<String> knownImageIds = const {},
    Set<EditorImage> skipImages = const {},
  }) {
    final ops = <NoteOp>[
      backgroundPattern(coreInfo.backgroundPattern),
      if (coreInfo.flashcards) flashcards(coreInfo),
    ];
    final sentAssets = <String>{};
    String? previousPageId;
    for (final page in coreInfo.pages) {
      // The blank page at the end is recreated by each device
      if (page == coreInfo.pages.last && page.isEmpty) break;
      ops.add(insertPage(page, afterPageId: previousPageId));
      for (final stroke in page.strokes) {
        if (knownStrokeIds.contains(stroke.id)) continue;
        ops.add(addStroke(page.id, stroke));
      }
      for (final image in _imagesOfPage(page)) {
        if (knownImageIds.contains(image.uid)) continue;
        if (skipImages.contains(image)) continue;
        ops.addAll(
          addImage(
            image,
            page,
            coreInfo,
            sentAssets: sentAssets,
            othersHaveNote: false,
          ),
        );
      }
      if (!page.quill.controller.document.isEmpty()) ops.add(text(page));
      if (page.study != null) ops.add(study(page));
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
    this.onImageAdded,
    Set<EditorImage>? unsizedImages,
  }) : unsizedImages = unsizedImages ?? {};

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

  /// Called with each image that another device added to the note.
  final void Function(EditorImage image)? onImageAdded;

  /// The ids of every stroke added by an applied operation.
  final addedStrokeIds = <String>{};

  /// The uids of every image added by an applied operation.
  final addedImageIds = <String>{};

  /// The local images that are sent once they've been sized,
  /// so they're left out of the operations until then.
  final Set<EditorImage> unsizedImages;

  /// The assets received from other devices, by their [NoteAssets.hashOf].
  final assets = <String, Uint8List>{};

  /// The pieces received so far of the assets that aren't complete yet.
  final _assetChunks = <String, List<Uint8List?>>{};

  /// Applies [op] to [coreInfo].
  ///
  /// [pendingLocalOps] are the local operations that haven't been
  /// acknowledged by the server yet. They'll be ordered after [op],
  /// so they take priority when both set the same value.
  ///
  /// [isUnsent] should return whether a local stroke has yet to be sent to
  /// the server, other than those added by [pendingLocalOps].
  ///
  /// [keepLocalText] should return whether the text of a page has local
  /// changes that will be sent after [op], so they replace its text.
  void apply(
    NoteOp op, {
    Iterable<NoteOp> pendingLocalOps = const [],
    bool Function(Stroke stroke)? isUnsent,
    bool Function(EditorPage page)? keepLocalText,
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
      case NoteOps.movePageType:
        _movePage(op);
      case NoteOps.backgroundPatternType:
        final overridden = pendingLocalOps.any(
          (pending) => pending['t'] == NoteOps.backgroundPatternType,
        );
        if (overridden) return;
        coreInfo.backgroundPattern = .fromName(op['p'] as String?);
      case NoteOps.assetChunkType:
        _addAssetChunk(op);
      case NoteOps.addImageType:
        _addImage(op);
      case NoteOps.removeImagesType:
        for (final String uid in (op['ids'] as List).cast()) {
          final (page, image) = _findImage(uid);
          if (page == null) continue;
          if (identical(page.backgroundImage, image)) {
            page.backgroundImage = null;
          } else {
            page.images.remove(image);
          }
        }
        removeExcessPages();
      case NoteOps.updateImageType:
        final overridden = pendingLocalOps.any(
          (pending) =>
              pending['t'] == NoteOps.updateImageType &&
              pending['id'] == op['id'],
        );
        if (overridden) return;
        _updateImage(op);
      case NoteOps.textType:
        final pageId = op['pg'] as String;
        final overridden = pendingLocalOps.any(
          (pending) =>
              pending['t'] == NoteOps.textType && pending['pg'] == pageId,
        );
        if (overridden) return;
        _setText(pageId, op['q'] as List, keepLocalText: keepLocalText);
      case NoteOps.flashcardsType:
        final overridden = pendingLocalOps.any(
          (pending) => pending['t'] == NoteOps.flashcardsType,
        );
        if (overridden) return;
        coreInfo.flashcards = op['on'] == true;
      case NoteOps.studyType:
        final pageId = op['pg'] as String;
        final overridden = pendingLocalOps.any(
          (pending) =>
              pending['t'] == NoteOps.studyType && pending['pg'] == pageId,
        );
        if (overridden) return;
        final index = _indexOfPage(pageId);
        if (index < 0) return;
        coreInfo.pages[index].study = op['c'] != null
            ? StudyState.fromJson(op['c'] as Map)
            : null;
      case NoteOps.textDeltaType:
        // [RealtimeSession] merges these with the local changes first
        applyTextChange(op['pg'] as String, Delta.fromJson(op['d'] as List));
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

  static Uint8List _bytes(dynamic value) => switch (value) {
    (final BsonBinary binary) => binary.byteList,
    (final Uint8List bytes) => bytes,
    (final List<dynamic> bytes) => Uint8List.fromList(bytes.cast()),
    _ => throw ArgumentError('Not bytes: ${value.runtimeType}'),
  };

  void _addAssetChunk(NoteOp op) {
    final hash = op['h'] as String;
    if (assets.containsKey(hash)) return;

    final count = opInt(op['n']), index = opInt(op['i']);
    final chunks = _assetChunks.putIfAbsent(
      hash,
      () => List.filled(count, null),
    );
    if (index < 0 || index >= chunks.length) return;
    chunks[index] = _bytes(op['b']);
    if (chunks.contains(null)) return;

    final bytes = BytesBuilder(copy: false);
    for (final chunk in chunks) {
      bytes.add(chunk!);
    }
    assets[hash] = bytes.takeBytes();
    _assetChunks.remove(hash);
  }

  /// Returns the asset with id [hash], which is [length] bytes long,
  /// if it was received or an image of the note already uses it.
  Uint8List? _findAsset(String hash, int length) {
    if (assets[hash] case final bytes?) return bytes;
    for (final image in NoteOps._imagesOf(coreInfo)) {
      try {
        final source = image.assetSource;
        if (NoteAssets.lengthOf(source) != length) continue;
        if (NoteAssets.hashOf(source) != hash) continue;
        return assets[hash] = NoteAssets.bytesOf(source);
      } catch (e) {
        log.warning('Failed to read the asset of image ${image.uid}: $e');
      }
    }
    return null;
  }

  void _addImage(NoteOp op) {
    final json = Map<String, dynamic>.from(op['m'] as Map);
    final uid = json['u'] as String;
    addedImageIds.add(uid);
    if (_findImage(uid).$2 != null) return;

    final bytes = _findAsset(op['h'] as String, opInt(op['n']));
    if (bytes == null) {
      log.severe('Image $uid was added without its asset ${op['h']}');
      return;
    }

    final pageIndex = _materializePage(op['pg'] as String);
    final page = coreInfo.pages[pageIndex];
    final image = EditorImage.fromJson(
      {...json, 'a': 0, 'i': pageIndex, 'id': coreInfo.nextImageId++},
      inlineAssets: [bytes],
      sbnPath: coreInfo.filePath,
      assetCache: coreInfo.assetCache,
    );
    if (op['bg'] == true) {
      _setBackground(page, image);
    } else {
      page.images.add(image);
    }
    onImageAdded?.call(image);

    createPage(pageIndex);
  }

  /// Makes [image] the background of [page], and the
  /// previous background (if any) a normal image again.
  void _setBackground(EditorPage page, EditorImage image) {
    if (identical(page.backgroundImage, image)) return;
    if (page.backgroundImage case final previous?) page.images.add(previous);
    page.images.remove(image);
    page.backgroundImage = image;
  }

  void _updateImage(NoteOp op) {
    final (page, image) = _findImage(op['id'] as String);
    if (page == null || image == null) return;

    double number(String key) => (op[key] as num).toDouble();
    image
      ..invertible = op['v'] as bool? ?? image.invertible
      ..backgroundFit =
          BoxFit.values[opInt(op['f'] ?? image.backgroundFit.index)]
      ..dstRect = .fromLTWH(number('x'), number('y'), number('w'), number('h'));
    final srcRect = Rect.fromLTWH(
      number('sx'),
      number('sy'),
      number('sw'),
      number('sh'),
    );
    if (!srcRect.isEmpty) image.srcRect = srcRect;

    if (op['bg'] == true) {
      _setBackground(page, image);
    } else if (identical(page.backgroundImage, image)) {
      page.backgroundImage = null;
      page.images.add(image);
    }
  }

  void _setText(
    String pageId,
    List<dynamic> json, {
    required bool Function(EditorPage page)? keepLocalText,
  }) {
    final pageIndex = _materializePage(pageId);
    final page = coreInfo.pages[pageIndex];
    if (keepLocalText?.call(page) ?? false) return;

    final controller = page.quill.controller;
    final current = controller.document.toDelta();
    final target = Delta.fromJson(json);
    if (current == target) return;

    Delta change;
    try {
      // a small change keeps the cursor where the user left it
      change = current.diff(target);
    } catch (e) {
      change = Delta()
        ..concat(target)
        ..delete(current.length);
    }
    if (change.isEmpty) return;
    _composeText(page, change);
    createPage(pageIndex);
  }

  /// Returns the page with id [pageId], creating it if needed.
  EditorPage pageForText(String pageId) =>
      coreInfo.pages[_materializePage(pageId)];

  /// Applies a [change] that another device made to the text of a page,
  /// after it has been transformed to apply to the text as it is here.
  void applyTextChange(String pageId, Delta change) {
    if (change.isEmpty) return;
    final pageIndex = _materializePage(pageId);
    _composeText(coreInfo.pages[pageIndex], change);
    createPage(pageIndex);
  }

  void _composeText(EditorPage page, Delta change) {
    final controller = page.quill.controller;

    // Undoing is for the user's own changes, so this one isn't recorded.
    final history = controller.document.history..ignoreChange = true;
    try {
      controller.compose(change, controller.selection, ChangeSource.remote);
    } finally {
      history.ignoreChange = false;
    }
    history.transform(change);

    page.syncedText = controller.document.toDelta();
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

  void _movePage(NoteOp op) {
    final from = _indexOfPage(op['id'] as String);
    if (from < 0) return;
    // the blank page at the end stays at the end
    if (from == coreInfo.pages.length - 1 && coreInfo.pages[from].isEmpty) {
      return;
    }
    final page = coreInfo.pages.removeAt(from);

    final after = op['after'] as String?;
    var to = 0;
    if (after != null) {
      final afterIndex = _indexOfPage(after);
      to = afterIndex < 0 ? coreInfo.pages.length : afterIndex + 1;
    }
    // never after the blank page at the end
    final last = coreInfo.pages.length - 1;
    if (to > last && last >= 0 && coreInfo.pages[last].isEmpty) to = last;
    coreInfo.pages.insert(to, page);
    _updatePageIndices(from: min(from, to));
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

  (EditorPage?, EditorImage?) _findImage(String uid) {
    for (final page in coreInfo.pages) {
      for (final image in NoteOps._imagesOfPage(page)) {
        if (image.uid == uid) return (page, image);
      }
    }
    return (null, null);
  }

  (EditorPage?, Stroke?) _findStroke(String id) {
    for (final page in coreInfo.pages) {
      for (final stroke in page.strokes) {
        if (stroke.id == id) return (page, stroke);
      }
    }
    return (null, null);
  }
}
