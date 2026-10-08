import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:collapsible/collapsible.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as flutter_quill;
import 'package:keybinder/keybinder.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/canvas_image.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/remote_cursors.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/components/editor/read_only_banner.dart';
import 'package:saber/components/sharing/share_dialog.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/theming/saber_theme.dart';
import 'package:saber/components/toolbar/color_bar.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/components/toolbar/editor_page_manager.dart';
import 'package:saber/components/toolbar/editor_page_panel.dart';
import 'package:saber/components/toolbar/editor_tab_bar.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/extensions/change_notifier_extensions.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart';
import 'package:saber/data/open_tabs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sync/realtime/account_syncer.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/data/sync/realtime/realtime_account.dart';
import 'package:saber/data/sync/realtime/realtime_session.dart';
import 'package:saber/data/sync/realtime/shared_notes.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/data/tools/tape.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/study.dart';
import 'package:saber/pages/home/whiteboard.dart';
import 'package:sbn/change.dart';
import 'package:super_clipboard/super_clipboard.dart';

typedef _PhotoInfo = ({Uint8List bytes, String extension});

class Editor extends StatefulWidget {
  new({super.key, String? path, this.customTitle, this.pdfPath})
    : initialPath = path != null
          ? Future.value(path)
          : FileManager.newFilePath('/'),
      needsNaming = path == null;

  final Future<String> initialPath;
  final bool needsNaming;

  final String? customTitle;
  final String? pdfPath;

  /// The file extension used by the app.
  /// Files with this extension are
  /// encoded in BSON format.
  static const extension = '.sbn2';

  /// The old file extension used by the app.
  /// Files with this extension are
  /// encoded in JSON format.
  static const extensionOldJson = '.sbn';

  static const double gapBetweenPages = 16;

  /// Returns true if [path] belongs to a hidden file
  /// used by other functions of the app
  static bool isReservedPath(String path) {
    return _reservedFilePaths.any((regex) => regex.hasMatch(path));
  }

  static final _reservedFilePaths = <RegExp>[
    RegExp(RegExp.escape(Whiteboard.filePath)),
  ];

  /// Whether the platform can rasterize a pdf
  static var canRasterPdf = true;

  @override
  State<Editor> createState() => EditorState();
}

class EditorState extends State<Editor> {
  final log = Logger('EditorState');

  late var coreInfo = EditorCoreInfo.placeholder;

  final _canvasGestureDetectorKey = GlobalKey<CanvasGestureDetectorState>();
  final _transformationController = TransformationController();
  double get scrollY {
    final transformation = _transformationController.value;
    final scale = transformation.approxScale;
    final translation = transformation.getTranslation();
    final gestureDetector = _canvasGestureDetectorKey.currentState;

    if (gestureDetector == null) {
      log.warning('scrollY: Could not find CanvasGestureDetectorState');
      return translation.y / scale;
    } else {
      final middle = gestureDetector.containerBounds.maxHeight / 2;
      return (translation.y - middle) / scale + middle;
    }
  }

  var history = EditorHistory();

  late bool needsNaming = widget.needsNaming && stows.editorPromptRename.value;

  late Tool _currentTool = () {
    switch (stows.lastTool.value) {
      case .fountainPen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.fountainPen();
        }
        return Pen.currentPen;
      case .ballpointPen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.ballpointPen();
        }
        return Pen.currentPen;
      case .shapePen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = ShapePen();
        }
        return Pen.currentPen;
      case .highlighter:
        return Highlighter.currentHighlighter;
      case .pencil:
        return Pencil.currentPencil;
      case .eraser:
        return Eraser();
      case .select:
        return Select.currentSelect;
      case .textEditing:
        return Tool.textEditing;
      case .laserPointer:
        return LaserPointer.currentLaserPointer;
      case .tape:
        return Tape.currentTape;
    }
  }();
  Tool get currentTool => _currentTool;
  set currentTool(Tool tool) {
    _currentTool = tool;
    if (tool is! Eraser) _lastNonEraserTool = tool;
    stows.lastTool.value = tool.toolId;
  }

  ValueNotifier<SavingState> savingState = ValueNotifier(SavingState.saved);
  Timer? _delayedSaveTimer;
  Timer? _watchServerTimer;

  /// Keeps this note in sync with the user's other devices as they write,
  /// or null if the user isn't signed in to an account.
  RealtimeSession? _realtime;

  /// The path that [AccountSyncer] was told is open in this editor.
  String? _pathOpenForSync;

  /// The path that [_realtime] was syncing when this editor was closed.
  String? _syncedPathWhenClosed;

  /// Whether the note has changes that aren't in [history],
  /// e.g. because they were made on another device.
  var _hasUnsavedRealtimeChanges = false;

  // used to prevent accidentally drawing when pinch zooming
  var lastSeenPointerCount = 0;
  Timer? _lastSeenPointerCountTimer;

  ValueNotifier<QuillStruct?> quillFocus = ValueNotifier(null);

  /// The last non-Eraser [currentTool] value.
  late Tool _lastNonEraserTool = Pen.currentPen;

  /// If the stylus button is pressed, or was pressed, during the current draw gesture.
  ///
  /// For now, this also includes when an [PointerDeviceKind.inverseStylus] is
  /// used since the stylus rear-end and stylus button currently act the same.
  /// If we add customized button bindings, we may have to separate this again.
  var stylusButtonWasPressed = false;

  @override
  void initState() {
    DynamicMaterialApp.addFullscreenListener(_setState);
    stows.openTabs.addListener(_setState);

    _initAsync();
    _assignKeybindings();

    super.initState();
  }

  void _initAsync() async {
    final filePath = await widget.initialPath;
    filenameTextEditingController.text = p.basename(filePath);

    if (needsNaming) {
      filenameTextEditingController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: filenameTextEditingController.text.length,
      );
    }

    await _loadCoreInfo(filePath);

    if (widget.pdfPath != null) {
      await importPdfFromFilePath(widget.pdfPath!);
    }
  }

  Future _loadCoreInfo(String filePath) async {
    coreInfo = await EditorCoreInfo.loadFromFilePath(filePath);
    if (coreInfo.readOnly) {
      log.info('Loaded file as read-only: ${coreInfo.readOnlyReason}');
    }

    for (int pageIndex = 0; pageIndex < coreInfo.pages.length; pageIndex++) {
      listenToQuillChanges(coreInfo.pages[pageIndex].quill, pageIndex);
    }

    if (coreInfo.isEmpty) {
      createPage(-1);
    } else {
      for (final page in coreInfo.pages) {
        if (page.backgroundImage case final image?) _listenToImage(image);
        page.images.forEach(_listenToImage);
      }
    }

    if (currentTool == Tool.textEditing) {
      int pageIndex;
      if (coreInfo.initialPageIndex != null) {
        pageIndex = coreInfo.initialPageIndex!;
      } else {
        pageIndex = 0;
      }
      assert(pageIndex < coreInfo.pages.length);

      quillFocus.value = coreInfo.pages[pageIndex].quill
        ..focusNode.requestFocus();
    }

    if (coreInfo.filePath == Whiteboard.filePath &&
        stows.autoClearWhiteboardOnExit.value &&
        Whiteboard.needsToAutoClearWhiteboard) {
      // clear whiteboard (and add to history)
      clearAllPages();

      // save cleared whiteboard
      await saveToFile();
      Whiteboard.needsToAutoClearWhiteboard = false;
    } else {
      setState(() {});
    }

    await _startRealtime();
  }

  /// The tab that was shown when this note was opened,
  /// so that this note's tab goes next to it.
  final _previousTab = OpenTabs.lastShown;

  /// Syncs this note with the user's account, if they're signed in to one.
  Future<void> _startRealtime() async {
    _realtime?.dispose();
    _realtime = null;
    history.onRecordChange = (item) => _submitRealtimeOps(item, inverse: false);

    // the note is ours to sync for as long as it's open
    if (_pathOpenForSync case final previousPath?) {
      AccountSyncer.instance.noteClosed(previousPath);
    }
    AccountSyncer.instance.noteOpened(coreInfo.filePath);
    _pathOpenForSync = coreInfo.filePath;
    if (widget.customTitle == null) {
      OpenTabs.open(coreInfo.filePath, after: _previousTab);
    }

    await RealtimeAccount.waitUntilLoaded();
    if (!mounted) return;
    if (!RealtimeAccount.isSignedIn || coreInfo.readOnly) return;

    final token = stows.realtimeToken.value;
    _presences.value = {};
    _realtime = RealtimeSession(
      serverUrl: RealtimeAccount.webSocketUrl,
      token: token,
      room: coreInfo.filePath,
      share: SharedNotes.tokenAt(coreInfo.filePath),
      onPresence: _onPresence,
      clientId: stows.realtimeClientId.value,
      applier: NoteOpApplier(
        coreInfo: coreInfo,
        createPage: createPage,
        removeExcessPages: removeExcessPages,
        onPageInserted: (page, pageIndex) =>
            listenToQuillChanges(page.quill, pageIndex),
        onImageAdded: _listenToImage,
        unsizedImages: _unsizedImages,
      ),
      onRemoteChange: () {
        if (!mounted) return;
        setState(() {});
        for (final page in coreInfo.pages) {
          page.redrawStrokes();
        }
      },
      onLocalStateChange: () {
        if (!mounted) return;
        _hasUnsavedRealtimeChanges = true;
        autosaveAfterDelay();
      },
      onStopped: (reason) {
        if (reason == .unauthorized) RealtimeAccount.sessionEnded(token);
      },
    )..start();
    setState(() {});
  }

  /// Where the other people who have this note open are, by their device.
  final _presences = ValueNotifier(<String, _Presence>{});
  Timer? _presenceCleanupTimer;

  void _onPresence(String from, String user, Map<String, dynamic>? presence) {
    if (!mounted) return;
    final presences = {..._presences.value};
    if (presence == null) {
      presences.remove(from);
    } else {
      presences[from] = (
        user: user,
        pageId: presence['pg'] as String? ?? '',
        position: Offset(
          (presence['x'] as num? ?? 0).toDouble(),
          (presence['y'] as num? ?? 0).toDouble(),
        ),
        down: presence['down'] == true,
        seen: DateTime.now(),
      );
    }
    _presences.value = presences;

    // someone who stops moving fades away after a while
    _presenceCleanupTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final remaining = {
        for (final MapEntry(:key, :value) in _presences.value.entries)
          if (now.difference(value.seen) < const Duration(seconds: 6))
            key: value,
      };
      if (remaining.length != _presences.value.length) {
        _presences.value = remaining;
      }
    });
  }

  var _lastPresenceSent = DateTime(0);

  /// Tells the other people who have the note open where this user's pen is.
  void _sendPresence(int pageIndex, Offset position, {required bool down}) {
    final realtime = _realtime;
    if (realtime == null || pageIndex >= coreInfo.pages.length) return;
    final now = DateTime.now();
    // a few times a second is enough to follow along
    if (down && now.difference(_lastPresenceSent).inMilliseconds < 60) return;
    _lastPresenceSent = now;
    realtime.sendPresence({
      'pg': coreInfo.pages[pageIndex].id,
      'x': position.dx,
      'y': position.dy,
      'down': down,
    });
  }

  /// Sends [item] (or the undoing of [item] if [inverse])
  /// to the user's other devices.
  void _submitRealtimeOps(EditorHistoryItem item, {required bool inverse}) {
    // An image that was just picked is sent once we know its size.
    for (final image in item.images) {
      if (image.dstRect.shortestSide != 0) continue;
      if (!_unsizedImages.add(image)) continue;
      unawaited(_submitImageWhenSized(image));
    }

    _submitOps(
      NoteOps.fromHistoryItem(
        item,
        coreInfo,
        inverse: inverse,
        skipImages: _unsizedImages,
      ),
    );
  }

  void _submitOps(List<NoteOp> ops) {
    if (ops.isEmpty) return;
    if (_realtime case final realtime?) {
      realtime.submit(ops);
    } else {
      // e.g. the user is signed out for now
      RealtimeSession.queueForLater(coreInfo, ops);
    }
  }

  /// The images that are waiting for [_submitImageWhenSized].
  final _unsizedImages = <EditorImage>{};

  Future<void> _submitImageWhenSized(EditorImage image) async {
    try {
      await image.waitForFirstLoad();
    } catch (e, st) {
      log.severe('Failed to load an image before syncing it: $e', e, st);
    }
    _unsizedImages.remove(image);
    if (!mounted) return;

    // it may have been removed again while it was loading
    final page = coreInfo.pages
        .where(
          (page) =>
              page.images.contains(image) || page.backgroundImage == image,
        )
        .firstOrNull;
    if (page == null) return;

    _submitOps(NoteOps.addImage(image, page, coreInfo, sentAssets: {}));
    autosaveAfterDelay();
  }

  /// Sends where and how [image] is shown to the user's other devices,
  /// for the changes to an image that aren't recorded in [history].
  void _submitImageUpdate(EditorImage? image) {
    if (image == null || _unsizedImages.contains(image)) return;
    _submitOps([NoteOps.updateImage(image, coreInfo)]);
  }

  void _listenToImage(EditorImage image) {
    image
      ..onMoveImage = onMoveImage
      ..onDeleteImage = onDeleteImage
      ..onMiscChange = () {
        _submitImageUpdate(image);
        autosaveAfterDelay();
      };
  }

  /// Saves a change that isn't recorded in [history],
  /// which is otherwise how we know that the note needs saving.
  void _saveChangeOutsideHistory() {
    _hasUnsavedRealtimeChanges = true;
    autosaveAfterDelay();
  }

  /// Whether the notes open as tabs are shown above the note.
  bool get _showTabs =>
      widget.customTitle == null &&
      coreInfo.filePath.isNotEmpty &&
      stows.openTabs.value.length >= 2 &&
      stows.openTabs.value.contains(coreInfo.filePath);

  /// Switches between turning pages one at a time and scrolling through them,
  /// staying on the same page.
  void _toggleHorizontalPaging() {
    final pageIndex = currentPageIndex;
    setState(() {
      stows.editorHorizontalPaging.value = !stows.editorHorizontalPaging.value;
    });
    CanvasGestureDetector.scrollToPage(
      pageIndex: pageIndex,
      pages: coreInfo.pages,
      screenWidth: MediaQuery.sizeOf(context).width,
      transformationController: _transformationController,
    );
  }

  /// Bookmarks the page at [pageIndex] under [title],
  /// or removes its bookmark if [title] is null.
  void _setBookmark(int pageIndex, String? title) {
    if (coreInfo.readOnly || pageIndex >= coreInfo.pages.length) return;
    final page = coreInfo.pages[pageIndex];
    if (page.bookmark == title) return;
    setState(() => page.bookmark = title);
    createPage(pageIndex);
    _submitOps([NoteOps.bookmark(page)]);
    _saveChangeOutsideHistory();
  }

  /// Lets the user rename or remove the bookmark of the page at [pageIndex].
  Future<void> _editBookmark(int pageIndex) async {
    final page = coreInfo.pages[pageIndex];
    final controller = TextEditingController(text: page.bookmark ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bookmark),
        title: Text(t.editor.bookmarks.edit),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: t.editor.bookmarks.title,
            hintText: t.editor.bookmarks.page(n: pageIndex + 1),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (text) => Navigator.pop(context, text.trim()),
        ),
        actions: [
          TextButton(
            // a value that can't be a title, to tell it apart from cancelling
            onPressed: () => Navigator.pop(context, '\u0000'),
            child: Text(t.editor.bookmarks.remove),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    _setBookmark(pageIndex, result == '\u0000' ? null : result);
  }

  /// Lets the user study this note's pages as flashcards.
  Future<void> _study() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => StudyPage(
          coreInfo: coreInfo,
          onGraded: (page) {
            _submitOps([NoteOps.study(page)]);
            _saveChangeOutsideHistory();
          },
        ),
      ),
    );
  }

  /// Sends the changes to the text of [page] to the user's other devices.
  void _textChanged(EditorPage page) {
    if (_realtime case final realtime?) {
      realtime.textChanged(page);
    } else {
      RealtimeSession.textChangedWithoutSession(coreInfo, page);
    }
  }

  /// Takes note of the text that was just typed, which we may not have
  /// been told about yet, so that it isn't saved without being sent.
  void _noteTextChanges() => coreInfo.pages.forEach(_textChanged);

  void _setState() => setState(() {});

  Keybinding? _ctrlZ, _ctrlY, _ctrlShiftZ;
  void _assignKeybindings() {
    _ctrlZ = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyZ),
    ], inclusive: true);
    _ctrlY = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyY),
    ], inclusive: true);
    _ctrlShiftZ = Keybinding([
      KeyCode.ctrl,
      KeyCode.shift,
      KeyCode.from(LogicalKeyboardKey.keyZ),
    ], inclusive: true);
    Keybinder.bind(_ctrlZ!, undo);
    Keybinder.bind(_ctrlY!, redo);
    Keybinder.bind(_ctrlShiftZ!, redo);
  }

  void _removeKeybindings() {
    if (_ctrlZ != null) Keybinder.remove(_ctrlZ!);
    if (_ctrlY != null) Keybinder.remove(_ctrlY!);
    if (_ctrlShiftZ != null) Keybinder.remove(_ctrlShiftZ!);
  }

  /// Creates pages until the given page index exists,
  /// plus an extra blank page
  void createPage(int pageIndex) {
    while (pageIndex >= coreInfo.pages.length - 1) {
      final page = EditorPage();
      coreInfo.pages.add(page);
      coreInfo.assignPageIds();
      listenToQuillChanges(page.quill, coreInfo.pages.length - 1);
    }
  }

  void removeExcessPages() {
    bool removedAPage = false;

    // remove excess pages if all pages >= this one are empty
    for (int i = coreInfo.pages.length - 1; i >= 1; --i) {
      final thisPage = coreInfo.pages[i];
      final prevPage = coreInfo.pages[i - 1];
      if (thisPage.isEmpty && prevPage.isEmpty) {
        final page = coreInfo.pages.removeAt(i);
        page.dispose();
        removedAPage = true;
      } else {
        break;
      }
    }

    if (removedAPage && CanvasGestureDetector.horizontalPaging) {
      // turn back to the last page if we were past it
      final lastIndex = coreInfo.pages.length - 1;
      final shownIndex = CanvasGestureDetector.horizontalPageIndex(
        transform: _transformationController.value,
        screenWidth: MediaQuery.sizeOf(context).width,
        pageCount: coreInfo.pages.length + 1,
      );
      if (shownIndex > lastIndex) {
        CanvasGestureDetector.scrollToPage(
          pageIndex: lastIndex,
          pages: coreInfo.pages,
          screenWidth: MediaQuery.sizeOf(context).width,
          transformationController: _transformationController,
        );
      }
    } else if (removedAPage) {
      // scroll to the last page (only if we're below the last page)

      final scrollY = this.scrollY;
      late final topOfLastPage = -CanvasGestureDetector.getTopOfPage(
        pageIndex: coreInfo.pages.length - 1,
        pages: coreInfo.pages,
        screenWidth: MediaQuery.sizeOf(context).width,
      );
      final bottomOfLastPage = -CanvasGestureDetector.getTopOfPage(
        pageIndex: coreInfo.pages.length,
        pages: coreInfo.pages,
        screenWidth: MediaQuery.sizeOf(context).width,
      );

      if (scrollY < bottomOfLastPage) {
        _transformationController.value = Matrix4.translationValues(
          0,
          // Slight upwards offset so that the page is not flush with the top of the screen
          topOfLastPage + 50,
          0,
        );
      }
    }
  }

  void undo([EditorHistoryItem? item]) {
    if (item == null) {
      if (!history.canUndo) return;

      // if we disabled redo, re-enable it
      if (!history.canRedo) {
        // no redo is possible, so clear the redo stack
        history.clearRedo();
        // don't disable redoing anymore
        history.canRedo = true;
      }

      item = history.undo();
    }

    setState(() {
      switch (item!.type) {
        case .draw:
          for (final stroke in item.strokes) {
            coreInfo.pages[stroke.pageIndex].strokes.remove(stroke);
          }
          for (final image in item.images) {
            coreInfo.pages[image.pageIndex].images.remove(image);
          }
          removeExcessPages();

        case .erase:
          for (final stroke in item.strokes) {
            createPage(stroke.pageIndex);
            coreInfo.pages[stroke.pageIndex].insertStroke(stroke);
          }
          for (final image in item.images) {
            createPage(image.pageIndex);
            coreInfo.pages[image.pageIndex].images.add(image);
            image.newImage = true;
          }

        case .deletePage:
          // make sure we already have a (blank/otherwise) page at this index
          createPage(item.pageIndex - 1);

          // a page created since the deletion may have taken this page's id
          final clash = coreInfo.pages
              .where((page) => page.id == item!.page!.id)
              .firstOrNull;
          if (clash != null) {
            if (clash.isEmpty) {
              clash.id = '';
            } else {
              item.page!.id = newId();
            }
          }

          // insert the page at the correct index
          coreInfo.pages.insert(item.pageIndex, item.page!);
          coreInfo.assignPageIds();

          // fix the page indices of all pages after this one
          for (int i = item.pageIndex + 1; i < coreInfo.pages.length; ++i) {
            final page = coreInfo.pages[i];
            page.updatePageIndex(i);
          }

        case .insertPage:
          // remove the page (which is usually at the given index)
          final index = coreInfo.pages.indexOf(item.page!);
          coreInfo.pages.removeAt(index >= 0 ? index : item.pageIndex);

          // fix the page indices of all pages after this one
          for (int i = item.pageIndex; i < coreInfo.pages.length; ++i) {
            final page = coreInfo.pages[i];
            page.updatePageIndex(i);
          }

        case .move:
          for (final stroke in item.strokes) {
            stroke.shift(Offset(-item.offset!.left, -item.offset!.top));
          }
          final select = Select.currentSelect;
          if (select.doneSelecting) {
            select.selectResult.path = select.selectResult.path.shift(
              Offset(-item.offset!.left, -item.offset!.top),
            );
          }
          for (final image in item.images) {
            image.dstRect = .fromLTRB(
              image.dstRect.left - item.offset!.left,
              image.dstRect.top - item.offset!.top,
              image.dstRect.right - item.offset!.right,
              image.dstRect.bottom - item.offset!.bottom,
            );
          }

        case .quillChange:
          final quill = coreInfo.pages[item.pageIndex].quill;
          quill.controller.undo();

        case .quillUndoneChange:
          final quill = coreInfo.pages[item.pageIndex].quill;
          quill.controller.redo();

        case .changeColor:
          for (final stroke in item.strokes) {
            stroke.color = item.colorChange![stroke]!.previous;
          }

        case .backgroundPattern:
          coreInfo.backgroundPattern = item.backgroundPatternChange!.previous;

        case .scale:
          final anchor = item.scaleAnchor!, factor = 1 / item.scaleFactor!;
          for (final stroke in item.strokes) {
            stroke.scale(anchor, factor);
          }
          for (final image in item.images) {
            image.dstRect = Rect.fromPoints(
              anchor + (image.dstRect.topLeft - anchor) * factor,
              anchor + (image.dstRect.bottomRight - anchor) * factor,
            );
          }
          final select = Select.currentSelect;
          if (select.doneSelecting) {
            final matrix = Matrix4.identity()
              ..translateByDouble(anchor.dx, anchor.dy, 0, 1)
              ..scaleByDouble(factor, factor, 1, 1)
              ..translateByDouble(-anchor.dx, -anchor.dy, 0, 1);
            select.selectResult.path = select.selectResult.path.transform(
              matrix.storage,
            );
          }

        case .split:
          for (final stroke in item.replacements) {
            for (final page in coreInfo.pages) {
              if (page.strokes.remove(stroke)) break;
            }
          }
          for (final stroke in item.strokes) {
            createPage(stroke.pageIndex);
            coreInfo.pages[stroke.pageIndex].insertStroke(stroke);
          }
          removeExcessPages();
      }

      if (item.type != .move && item.type != .scale) {
        Select.currentSelect.unselect();
      }
    });

    _submitRealtimeOps(item, inverse: true);
    autosaveAfterDelay();
  }

  void redo() {
    if (!history.canRedo) return;
    final item = history.redo();

    switch (item.type) {
      case .draw:
        undo(item.copyWith(type: .erase));
      case .erase:
        undo(item.copyWith(type: .draw));
      case .deletePage:
        undo(item.copyWith(type: .insertPage));
      case .insertPage:
        undo(item.copyWith(type: .deletePage));
      case .move:
        undo(
          item.copyWith(
            offset: .fromLTRB(
              -item.offset!.left,
              -item.offset!.top,
              -item.offset!.right,
              -item.offset!.bottom,
            ),
          ),
        );
      case .quillChange:
        undo(item.copyWith(type: .quillUndoneChange));
      case .quillUndoneChange: // this will never happen
        throw Exception('history should not contain quillUndoneChange items');
      case .changeColor:
        undo(
          item.copyWith(
            colorChange: item.colorChange!.map(
              (key, value) => MapEntry(key, value.reverse()),
            ),
          ),
        );
      case .backgroundPattern:
        undo(
          item.copyWith(
            backgroundPatternChange: item.backgroundPatternChange!.reverse(),
          ),
        );
      case .split:
        undo(
          item.copyWith(strokes: item.replacements, replacements: item.strokes),
        );
      case .scale:
        undo(item.copyWith(scaleFactor: 1 / item.scaleFactor!));
    }
  }

  int? onWhichPageIsFocalPoint(Offset focalPoint) {
    for (int i = 0; i < coreInfo.pages.length; ++i) {
      if (coreInfo.pages[i].renderBox == null) continue;
      final pageBounds = Offset.zero & coreInfo.pages[i].size;
      if (pageBounds.contains(
        coreInfo.pages[i].renderBox!.globalToLocal(focalPoint),
      ))
        return i;
    }
    return null;
  }

  /// The position of the previous draw gesture event.
  /// Used to move a selection.
  Offset previousPosition = .zero;

  /// While the selection is being resized: the corner that stays in place,
  /// where the handle was grabbed, and how much bigger the selection is.
  Offset? _resizeAnchor, _resizeStart;
  var _resizeFactor = 1.0;

  /// The total offset of the current move gesture.
  /// Used to record a move in the history.
  Offset moveOffset = .zero;

  var isHovering = true;
  int? dragPageIndex;
  PointerDeviceKind? currentPointerKind;
  double? currentPressure;
  bool isDrawGesture(ScaleStartDetails details) {
    if (coreInfo.readOnly) return false;

    CanvasImage.activeListener
        .notifyListenersPlease(); // un-select active image

    _lastSeenPointerCountTimer?.cancel();
    if (lastSeenPointerCount >= 2) {
      // was a zoom gesture, ignore
      lastSeenPointerCount = lastSeenPointerCount;
      return false;
    } else if (details.pointerCount >= 2) {
      // is a zoom gesture, remove accidental stroke
      if (lastSeenPointerCount == 1 &&
          stows.editorFingerDrawing.value &&
          (currentTool is Pen || currentTool is Eraser)) {
        final item = history.removeAccidentalStroke();
        if (item != null) undo(item);
      }
      lastSeenPointerCount = details.pointerCount;
      return false;
    } else {
      // is a stroke
      lastSeenPointerCount = details.pointerCount;
    }

    dragPageIndex = onWhichPageIsFocalPoint(details.focalPoint);
    if (dragPageIndex == null) return false;

    if (currentTool == Tool.textEditing) {
      return false;
    } else if (stows.editorFingerDrawing.value ||
        currentPointerKind == PointerDeviceKind.stylus ||
        currentPointerKind == PointerDeviceKind.invertedStylus ||
        currentPressure != null) {
      return true;
    } else {
      log.fine('Non-stylus found, rejected stroke');
      return false;
    }
  }

  void onDrawStart(ScaleStartDetails details) {
    final page = coreInfo.pages[dragPageIndex!];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    history.canRedo = false;

    if (currentTool is Pen) {
      (currentTool as Pen).onDragStart(
        position,
        page,
        dragPageIndex!,
        currentPressure,
      );
    } else if (currentTool is Eraser) {
      (currentTool as Eraser).erase(position, page.strokes);
      removeExcessPages();
    } else if (currentTool is Select) {
      final select = currentTool as Select;
      final selection = select.selectResult;
      if (select.doneSelecting &&
          selection.pageIndex == dragPageIndex! &&
          !selection.isEmpty &&
          (position - selection.resizeHandle).distance <=
              SelectResult.resizeHandleRadius) {
        // resize from the handle, keeping the opposite corner in place
        _resizeAnchor = selection.bounds.topLeft;
        _resizeStart = selection.resizeHandle;
        _resizeFactor = 1;
      } else if (select.doneSelecting &&
          selection.pageIndex == dragPageIndex! &&
          selection.path.contains(position)) {
        // drag selection in onDrawUpdate
      } else {
        select.onDragStart(position, dragPageIndex!);
        history.canRedo = true; // selection doesn't affect history
      }
    } else if (currentTool is LaserPointer) {
      (currentTool as LaserPointer).onDragStart(position, page, dragPageIndex!);
    }

    previousPosition = position;
    moveOffset = .zero;
    _sendPresence(dragPageIndex!, position, down: true);

    if (currentTool is! Select) {
      Select.currentSelect.unselect();
    }

    // setState to let canvas know about currentStroke
    setState(() {});
  }

  void onDrawUpdate(ScaleUpdateDetails details) {
    final page = coreInfo.pages[dragPageIndex!];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    final offset = position - previousPosition;

    if (currentTool is Pen) {
      (currentTool as Pen).onDragUpdate(position, currentPressure);
      page.redrawStrokes();
    } else if (currentTool is Eraser) {
      // the eraser may have skipped over part of the page since the last
      // update, so erase along the way too
      final eraser = currentTool as Eraser;
      final distance = (position - previousPosition).distance;
      final steps = (distance / max(eraser.size / 2, 1)).ceil().clamp(1, 50);
      var changed = false;
      for (int i = 1; i <= steps; ++i) {
        final point = Offset.lerp(previousPosition, position, i / steps)!;
        changed = eraser.erase(point, page.strokes) || changed;
      }
      if (changed) {
        page.redrawStrokes();
        removeExcessPages();
      }
    } else if (currentTool is Select) {
      final select = currentTool as Select;
      if (_resizeAnchor case final anchor?) {
        final start = _resizeStart! - anchor;
        final current = position - anchor;
        // how far along the diagonal the handle was dragged
        final factor =
            ((current.dx * start.dx + current.dy * start.dy) /
                    start.distanceSquared)
                .clamp(0.05, 20.0);
        select.selectResult.scale(anchor, factor / _resizeFactor);
        _resizeFactor = factor;
      } else if (select.doneSelecting) {
        for (final stroke in select.selectResult.strokes) {
          stroke.shift(offset);
        }
        for (final image in select.selectResult.images) {
          image.dstRect = image.dstRect.shift(offset);
        }
        select.selectResult.path = select.selectResult.path.shift(offset);
      } else {
        select.onDragUpdate(position);
      }
      page.redrawStrokes();
    } else if (currentTool is LaserPointer) {
      (currentTool as LaserPointer).onDragUpdate(position);
      page.redrawStrokes();
    }
    previousPosition = position;
    moveOffset += offset;
    _sendPresence(dragPageIndex!, position, down: true);
  }

  void onDrawEnd(ScaleEndDetails details) {
    final page = coreInfo.pages[dragPageIndex!];
    _sendPresence(dragPageIndex!, previousPosition, down: false);
    bool shouldSave = true;
    setState(() {
      if (currentTool is Pen) {
        final newStroke = (currentTool as Pen).onDragEnd();
        if (newStroke == null) return;
        if (newStroke.isEmpty) return;

        // tapping tape shows or hides what's under it
        if (newStroke.isTap) {
          final tape = Tape.tapeAt(newStroke.firstPoint!, page.strokes);
          if (tape != null) {
            tape.revealed = !tape.revealed;
            page.redrawStrokes();
            shouldSave = false;
            return;
          }
        }
        if (newStroke.toolId == .tape && newStroke.isStraightLine()) {
          newStroke.convertToLine();
        }

        if (stows.autoStraightenLines.value &&
            currentTool is! ShapePen &&
            newStroke.isStraightLine()) {
          newStroke.convertToLine();
        }

        createPage(newStroke.pageIndex);
        page.insertStroke(newStroke);
        history.recordChange(
          EditorHistoryItem(
            type: .draw,
            pageIndex: dragPageIndex!,
            strokes: [newStroke],
            images: [],
          ),
        );
      } else if (currentTool is Eraser) {
        final (:erased, :pieces) = (currentTool as Eraser).onDragEnd();
        if (stylusButtonWasPressed || stows.disableEraserAfterUse.value) {
          // restore previous tool
          stylusButtonWasPressed = false;
          currentTool = _lastNonEraserTool;
        }
        if (erased.isEmpty) return;
        history.recordChange(
          EditorHistoryItem(
            type: pieces.isEmpty ? .erase : .split,
            pageIndex: dragPageIndex!,
            strokes: erased,
            images: [],
            replacements: pieces,
          ),
        );
      } else if (currentTool is Select && _resizeAnchor != null) {
        final select = currentTool as Select;
        final anchor = _resizeAnchor!, factor = _resizeFactor;
        _resizeAnchor = _resizeStart = null;
        if (factor == 1) return;
        history.recordChange(
          EditorHistoryItem(
            type: .scale,
            pageIndex: dragPageIndex!,
            strokes: select.selectResult.strokes.toList(),
            images: select.selectResult.images.toList(),
            scaleAnchor: anchor,
            scaleFactor: factor,
          ),
        );
      } else if (currentTool is Select) {
        if (moveOffset == .zero) return;
        final select = currentTool as Select;
        if (select.doneSelecting) {
          history.recordChange(
            EditorHistoryItem(
              type: .move,
              pageIndex: dragPageIndex!,
              strokes: select.selectResult.strokes,
              images: select.selectResult.images,
              offset: .fromLTRB(
                moveOffset.dx,
                moveOffset.dy,
                moveOffset.dx,
                moveOffset.dy,
              ),
            ),
          );
        } else {
          shouldSave = false;
          select.onDragEnd(page.strokes, page.images);

          if (select.selectResult.isEmpty) {
            Select.currentSelect.unselect();
          }
        }
      } else if (currentTool is LaserPointer) {
        shouldSave = false;
        final newStroke = (currentTool as LaserPointer).onDragEnd(
          page.redrawStrokes,
          (Stroke stroke) {
            page.laserStrokes.remove(stroke);
          },
        );
        if (newStroke != null) page.laserStrokes.add(newStroke);
      }
    });

    if (shouldSave) autosaveAfterDelay();
  }

  void onInteractionEnd(ScaleEndDetails details) {
    // reset after 1ms to keep track of the same gesture only
    _lastSeenPointerCountTimer?.cancel();
    _lastSeenPointerCountTimer = Timer(const Duration(milliseconds: 10), () {
      lastSeenPointerCount = 0;
    });
  }

  void updatePointerData(PointerDeviceKind kind, double? pressure) {
    currentPointerKind = kind;
    currentPressure = pressure;
  }

  void onHovering() {
    isHovering = true;
  }

  void onHoveringEnd() {
    isHovering = false;
  }

  void onStylusButtonChanged(bool buttonIsPressed) {
    stylusButtonWasPressed |= buttonIsPressed;

    if (!isHovering) return;
    if (buttonIsPressed) {
      // button pressed while hovering, switch to Eraser
      if (currentTool is! Eraser) {
        currentTool = Eraser();
      }
    } else {
      // button was released while hovering, switch back to non-Eraser
      if (currentTool is Eraser) {
        currentTool = _lastNonEraserTool;
      }
    }

    if (mounted) setState(() {});
  }

  void onMoveImage(EditorImage image, Rect offset) {
    history.recordChange(
      EditorHistoryItem(
        type: .move,
        pageIndex: image.pageIndex,
        strokes: [],
        images: [image],
        offset: offset,
      ),
    );
    // setState to update undo button
    setState(() {});
    autosaveAfterDelay();
  }

  void onDeleteImage(EditorImage image) {
    history.recordChange(
      EditorHistoryItem(
        type: .erase,
        pageIndex: image.pageIndex,
        strokes: [],
        images: [image],
      ),
    );
    setState(() {
      coreInfo.pages[image.pageIndex].images.remove(image);
    });
    autosaveAfterDelay();
  }

  void listenToQuillChanges(QuillStruct quill, int pageIndex) {
    quill.changeSubscription?.cancel();
    quill.changeSubscription = quill.controller.changes.listen((event) {
      // the page may have moved since we started listening
      final page = coreInfo.pages
          .where((page) => page.quill == quill)
          .firstOrNull;
      if (page != null) pageIndex = coreInfo.pages.indexOf(page);

      if (event.source == flutter_quill.ChangeSource.remote) {
        // another device's change, which [_realtime] saves
        createPage(pageIndex);
        if (mounted) setState(() {});
        return;
      }

      final undoRedoButtonsNeedUpdating = !history.canUndo || history.canRedo;
      _addQuillChangeToHistory(
        quill: quill,
        pageIndex: pageIndex,
        event: event,
      );
      createPage(pageIndex); // create empty last page
      if (undoRedoButtonsNeedUpdating) {
        setState(() {});
      }
      if (page != null) _textChanged(page);
      autosaveAfterDelay();
    });
    quill.focusNode.addListener(_onQuillFocusChange);
  }

  void _onQuillFocusChange() {
    for (final page in coreInfo.pages) {
      if (!page.quill.focusNode.hasFocus) continue;
      quillFocus.value = page.quill;
    }
  }

  void _addQuillChangeToHistory({
    required QuillStruct quill,
    required int pageIndex,
    required flutter_quill.DocChange event,
  }) {
    final eventWasUndo = quill.controller.hasRedo;
    if (eventWasUndo) return;

    // the change subscription sometimes fires multiple times for the same change
    // so compare the "before" of each change to merge them
    if (history.canUndo && !history.canRedo) {
      final lastChange = history.peekUndo();
      if (lastChange.type == .quillChange &&
          lastChange.pageIndex == pageIndex &&
          lastChange.quillChange!.before == event.before) {
        history.undo(); // remove the last change, to be replaced
      }
    }

    history.recordChange(
      EditorHistoryItem(
        type: .quillChange,
        pageIndex: pageIndex,
        strokes: const [],
        images: const [],
        quillChange: event,
      ),
    );
  }

  void _refreshCurrentNote() async {
    if (coreInfo.readOnlyReason != .watchingServer) return;
    if (!stows.loggedIn) return;

    final relativeFilePath = coreInfo.filePath;
    assert(relativeFilePath.isNotEmpty, 'Cannot refresh unnamed file');
    final syncFile = await SaberSyncFile.relative(
      relativeFilePath + Editor.extension,
    );

    final bestFile = await SaberSyncInterface.getBestFile(
      syncFile,
      onLocalFileNotFound: .local,
      onEqualFiles: .local,
      preferCache: false,
    );
    if (bestFile != .remote) return;

    late final StreamSubscription<SaberSyncFile> subscription;
    void listener(SaberSyncFile transferred) {
      if (transferred != syncFile) return;
      subscription.cancel();
      _loadCoreInfo(relativeFilePath)
          .then((_) => coreInfo.readOnlyReason = .watchingServer);
    }

    subscription = syncer.downloader.transferStream.listen(listener);

    await syncer.downloader.enqueue(syncFile: syncFile);
    syncer.downloader.bringToFront(syncFile);
  }

  void autosaveAfterDelay() {
    if (history.isCurrentStateSaved && !_hasUnsavedRealtimeChanges) {
      return cancelAutosaveAndMarkSaved();
    }

    late final void Function() callback;

    void startTimer() {
      _delayedSaveTimer?.cancel();
      if (stows.autosaveDelay.value < 0) return;
      _delayedSaveTimer = Timer(
        Duration(milliseconds: stows.autosaveDelay.value),
        callback,
      );
    }

    callback = () {
      if (Pen.currentStroke != null) {
        // don't save yet if the pen is currently drawing
        startTimer();
        return;
      }
      saveToFile();
    };

    savingState.value = .waitingToSave;
    startTimer();
  }

  void cancelAutosaveAndMarkSaved() {
    _delayedSaveTimer?.cancel();
    savingState.value = .saved;
    history.markLastChangeAsSaved();
  }

  Future<void> saveToFile() async {
    if (coreInfo.readOnly) return;
    _noteTextChanges();

    switch (savingState.value) {
      case .saved:
        // avoid saving if nothing has changed
        return;
      case .saving:
        // avoid saving if already saving
        log.warning('saveToFile() called while already saving');
        return;
      case .waitingToSave:
        // continue
        _delayedSaveTimer?.cancel();
        savingState.value = .saving;
    }
    if (history.isCurrentStateSaved && !_hasUnsavedRealtimeChanges) {
      return cancelAutosaveAndMarkSaved();
    }

    await _renameFileNow();

    final filePath = coreInfo.filePath + Editor.extension;
    final Uint8List bson;
    final OrderedAssetCache assets;
    coreInfo.assetCache.allowRemovingAssets = false;
    final hadUnsavedRealtimeChanges = _hasUnsavedRealtimeChanges;
    _hasUnsavedRealtimeChanges = false;
    try {
      (bson, assets) = coreInfo.saveToBinary(
        currentPageIndex: currentPageIndex,
      );
    } finally {
      coreInfo.assetCache.allowRemovingAssets = true;
    }
    try {
      await Future.wait([
        FileManager.writeFile(filePath, bson, awaitWrite: true),
        for (int i = 0; i < assets.length; ++i)
          assets
              .getBytes(i)
              .then(
                (bytes) => FileManager.writeFile(
                  '$filePath.$i',
                  bytes,
                  awaitWrite: true,
                ),
              ),
        FileManager.removeUnusedAssets(filePath, numAssets: assets.length),
      ]);
      savingState.value = .saved;
      history.markLastChangeAsSaved();
      // the note may have been changed by another device while we were saving
      if (_hasUnsavedRealtimeChanges && mounted) autosaveAfterDelay();
    } catch (e, st) {
      log.severe('Failed to save file: $e', e, st);
      _hasUnsavedRealtimeChanges |= hadUnsavedRealtimeChanges;
      savingState.value = .waitingToSave;
      if (kDebugMode) rethrow;
      return;
    }

    if (!mounted) return;
    final page = coreInfo.pages.first;
    final previewHeight = page.previewHeight(lineHeight: coreInfo.lineHeight);
    final thumbnailSize = Size(720, 720 * previewHeight / page.size.width);
    final thumbnail = await EditorExporter.screenshotPage(
      coreInfo: coreInfo,
      pageIndex: 0,
      rasterizeAllStrokes: true,
      targetSize: thumbnailSize,
      cropHeight: previewHeight,
      pixelRatio: 1,
    );
    final thumbnailPng = await thumbnail.toByteData(format: .png);
    thumbnail.dispose();
    await FileManager.writeFile(
      // Note that this ends with .sbn2.p
      '$filePath.p',
      thumbnailPng!.buffer.asUint8List(),
      awaitWrite: true,
    );
  }

  late final _filenameFormKey = GlobalKey<FormState>();
  late final filenameTextEditingController = TextEditingController();
  Timer? _renameTimer;
  void renameFile([String? _]) {
    _renameTimer?.cancel();
    _renameTimer = Timer(const Duration(seconds: 5), _renameFileNow);
  }

  Future<void> _renameFileNow() async {
    final newName = filenameTextEditingController.text.trim();
    if (newName == coreInfo.fileName) return;

    if (_filenameFormKey.currentState?.validate() ??
        _validateFilenameTextField(newName) == null) {
      coreInfo.filePath = await FileManager.moveFile(
        coreInfo.filePath + Editor.extension,
        newName.trim() + Editor.extension,
      );
      coreInfo.filePath = coreInfo.filePath.substring(
        0,
        coreInfo.filePath.lastIndexOf(Editor.extension),
      );
      needsNaming = false;

      // notes are matched between devices by their path
      if (mounted) unawaited(_startRealtime());
    }

    final actualName = coreInfo.fileName;
    if (actualName != newName) {
      // update text field if renamed differently
      filenameTextEditingController.value = filenameTextEditingController.value
          .copyWith(
            text: actualName,
            selection: TextSelection.fromPosition(
              TextPosition(offset: actualName.length),
            ),
            composing: TextRange.empty,
          );
    }
  }

  String? _validateFilenameTextField(String? newName) {
    if (newName == null) return null;
    return FileManager.validateFilename(newName);
  }

  void updateColorBar(Color color) {
    if (stows.recentColorsDontSavePresets.value) {
      if (ColorBar.colorPresets.any(
        (colorPreset) => colorPreset.color == color,
      )) {
        return;
      }
    }

    final newColorString = color.toARGB32().toString();

    // migrate from old pref format
    if (stows.recentColorsChronological.value.length !=
        stows.recentColorsPositioned.value.length) {
      log.info(
        'MIGRATING recentColors: ${stows.recentColorsChronological.value.length} vs ${stows.recentColorsPositioned.value.length}',
      );
      stows.recentColorsChronological.value = List.of(
        stows.recentColorsPositioned.value,
      );
    }

    if (stows.pinnedColors.value.contains(newColorString)) {
      // do nothing, color is already pinned
    } else if (stows.recentColorsPositioned.value.contains(newColorString)) {
      // if it's already a recent color, move it to the top
      stows.recentColorsChronological.value.remove(newColorString);
      stows.recentColorsChronological.value.add(newColorString);
      stows.recentColorsChronological.notifyListeners();
    } else {
      if (stows.recentColorsPositioned.value.length >=
          stows.recentColorsLength.value) {
        // if full, replace the oldest color with the new one
        final removedColorString = stows.recentColorsChronological.value
            .removeAt(0);
        stows.recentColorsChronological.value.add(newColorString);
        final int removedColorPosition = stows.recentColorsPositioned.value
            .indexOf(removedColorString);
        stows.recentColorsPositioned.value[removedColorPosition] =
            newColorString;
      } else {
        // if not full, add the new color to the end
        stows.recentColorsChronological.value.add(newColorString);
        stows.recentColorsPositioned.value.insert(0, newColorString);
      }
      stows.recentColorsChronological.notifyListeners();
      stows.recentColorsPositioned.notifyListeners();
    }
  }

  /// Prompts the user to pick photos from their device.
  /// Returns the number of photos picked.
  ///
  /// If [photoInfos] is provided, it will be used instead of the file picker.
  Future<int> _pickPhotos([List<_PhotoInfo>? photoInfos]) async {
    if (coreInfo.readOnly) return 0;

    final currentPageIndex = this.currentPageIndex;

    photoInfos ??= await _pickPhotosWithFilePicker();
    if (photoInfos.isEmpty) return 0;

    // use the Select tool so that the user can move the new image
    currentTool = Select.currentSelect;

    final images = [
      for (final _PhotoInfo photoInfo in photoInfos)
        if (photoInfo.extension == '.svg')
          SvgEditorImage(
            id: coreInfo.nextImageId++,
            svgString: utf8.decode(photoInfo.bytes),
            svgFile: null,
            pageIndex: currentPageIndex,
            pageSize: coreInfo.pages[currentPageIndex].size,
            onMoveImage: onMoveImage,
            onDeleteImage: onDeleteImage,
            onMiscChange: autosaveAfterDelay,
            onLoad: () => setState(() {}),
            assetCache: coreInfo.assetCache,
          )
        else
          PngEditorImage(
            id: coreInfo.nextImageId++,
            extension: photoInfo.extension,
            imageProvider: MemoryImage(photoInfo.bytes),
            pageIndex: currentPageIndex,
            pageSize: coreInfo.pages[currentPageIndex].size,
            onMoveImage: onMoveImage,
            onDeleteImage: onDeleteImage,
            onMiscChange: autosaveAfterDelay,
            onLoad: () => setState(() {}),
            assetCache: coreInfo.assetCache,
          ),
    ];
    images.forEach(_listenToImage);

    history.recordChange(
      EditorHistoryItem(
        type: .draw,
        pageIndex: currentPageIndex,
        strokes: [],
        images: images,
      ),
    );
    createPage(currentPageIndex);
    coreInfo.pages[currentPageIndex].images.addAll(images);
    autosaveAfterDelay();

    return images.length;
  }

  Future<List<_PhotoInfo>> _pickPhotosWithFilePicker() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      // Taken from
      // https://github.com/brendan-duncan/image/blob/main/doc/formats.md
      // (plus .svg)
      allowedExtensions: [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'tiff',
        'bmp',
        'tga',
        'ico',
        'pvrtc',
        'svg',
        'webp',
        'psd',
        'exr',
      ],
    );
    if (files.isEmpty) return const [];

    return Future.wait([
      for (final file in files)
        () async {
          final extension = p.extension(file.path ?? file.name);
          if (extension.isEmpty) return null;
          final bytes = await file.readAsBytes();
          return (bytes: bytes, extension: extension);
        }(),
    ]).then((list) => list.nonNulls.toList());
  }

  /// Prompts the user to pick a PDF to import.
  /// Returns whether a PDF was picked.
  Future<bool> importPdf() async {
    if (coreInfo.readOnly) return false;
    if (!Editor.canRasterPdf) return false;

    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (file == null) return false;

    return importPdfFromFilePath(file.path!);
  }

  Future<bool> importPdfFromFilePath(String path) async {
    final pdfDocument = await coreInfo.assetCache.pdfDocumentCache.load(path);

    final emptyPage = coreInfo.pages.removeLast();
    assert(emptyPage.isEmpty);

    for (final pdfPage in pdfDocument.pages) {
      assert(pdfPage.pageNumber >= 1, 'pdfrx page numbers start at 1');

      // resize to [defaultWidth] to keep pen sizes consistent
      final pageSize = Size(
        EditorPage.defaultWidth,
        EditorPage.defaultWidth * pdfPage.height / pdfPage.width,
      );

      final page = EditorPage(
        id: newId(),
        size: pageSize,
        backgroundImage: PdfEditorImage(
          id: coreInfo.nextImageId++,
          pdfBytes: null,
          pdfFile: File(path),
          pdfPage: pdfPage.pageNumber - 1,
          pageIndex: coreInfo.pages.length,
          pageSize: pageSize,
          naturalSize: pdfPage.size,
          onMoveImage: onMoveImage,
          onDeleteImage: onDeleteImage,
          onMiscChange: autosaveAfterDelay,
          onLoad: () => setState(() {}),
          assetCache: coreInfo.assetCache,
        ),
      );
      _listenToImage(page.backgroundImage!);
      coreInfo.pages.add(page);
      // TODO(adil192): Group multiple pages into one atomic change
      history.recordChange(
        EditorHistoryItem(
          type: .insertPage,
          pageIndex: coreInfo.pages.length - 1,
          strokes: const [],
          images: const [],
          page: page,
        ),
      );
    }

    coreInfo.pages.add(emptyPage);
    if (mounted) setState(() {});

    autosaveAfterDelay();

    return true;
  }

  Future paste() async {
    /// Maps image formats to their file extension.
    const Map<SimpleFileFormat, String> formats = {
      Formats.jpeg: '.jpeg',
      Formats.png: '.png',
      Formats.gif: '.gif',
      Formats.tiff: '.tiff',
      Formats.bmp: '.bmp',
      Formats.ico: '.ico',
      Formats.svg: '.svg',
      Formats.webp: '.webp',
    };

    final reader = await SystemClipboard.instance?.read();
    if (reader == null) return;

    final List<_PhotoInfo> photoInfos = [];
    final List<ReadProgress> progresses = [];

    for (final format in formats.keys) {
      if (!reader.canProvide(format)) continue;
      final progress = reader.getFile(format, (file) async {
        final stream = file.getStream();
        final List<int> bytes = [];
        await for (final chunk in stream) {
          bytes.addAll(chunk);
        }
        if (bytes.isEmpty) {
          log.warning('Pasted empty file: $file (${formats[format]})');
          return;
        }

        String extension;
        if (file.fileName != null) {
          extension = file.fileName!.substring(file.fileName!.lastIndexOf('.'));
        } else {
          extension = formats[format]!;
        }

        photoInfos.add((
          bytes: Uint8List.fromList(bytes),
          extension: extension,
        ));
      });
      if (progress != null) progresses.add(progress);
    }

    while (progresses.isNotEmpty) {
      progresses.removeWhere((progress) => progress.fraction.value == 1);
      await Future.delayed(const Duration(milliseconds: 50));
    }

    await _pickPhotos(photoInfos);
  }

  Future exportAsPdf(BuildContext context) async {
    final pdf = await EditorExporter.generatePdf(coreInfo, context);
    final bytes = await pdf.save();
    if (!context.mounted) return;
    await FileManager.exportFile(
      '${coreInfo.fileName}.pdf',
      bytes,
      context: context,
    );
  }

  /// Exports the current note as an SBA (Saber Archive) file.
  Future exportAsSba(BuildContext context) async {
    final sba = await coreInfo.saveToSba(currentPageIndex: currentPageIndex);
    if (!context.mounted) return;
    await FileManager.exportFile(
      '${coreInfo.fileName}.sba',
      Uint8List.fromList(sba),
      context: context,
    );
  }

  /// Exports the current page as a PNG image file.
  ///
  /// This captures the canvas natively via [EditorExporter.screenshotPage],
  /// which guarantees the correct background color and omits UI elements
  /// like selection bounds or the text cursor. It computes a dynamic [pixelRatio]
  /// to ensure high quality while averting Out-Of-Memory exceptions on large canvases.
  Future exportAsPng(BuildContext context) async {
    final page = coreInfo.pages[currentPageIndex];

    const maxRasterizableSize = 3000.0;
    var targetPixelRatio = maxRasterizableSize / page.size.longestSide;
    if (targetPixelRatio > 1) targetPixelRatio = 1;

    try {
      final image = await EditorExporter.screenshotPage(
        coreInfo: coreInfo,
        pageIndex: currentPageIndex,
        rasterizeAllStrokes: true,
        pixelRatio: targetPixelRatio,
      );
      final pngBytes = await image.toByteData(format: .png);
      image.dispose();

      if (!context.mounted) return;
      await FileManager.exportFile(
        '${coreInfo.fileName}_page_${currentPageIndex + 1}.png',
        pngBytes!.buffer.asUint8List(),
        isImage: true,
        context: context,
      );
    } catch (e, st) {
      log.severe('Failed to export PNG', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final platform = Theme.of(context).platform;
    final isToolbarVertical =
        stows.editorToolbarAlignment.value == AxisDirection.left ||
        stows.editorToolbarAlignment.value == AxisDirection.right;

    final Widget canvas = CanvasGestureDetector(
      key: _canvasGestureDetectorKey,
      filePath: coreInfo.filePath,
      isDrawGesture: isDrawGesture,
      onInteractionEnd: onInteractionEnd,
      onDrawStart: onDrawStart,
      onDrawUpdate: onDrawUpdate,
      onDrawEnd: onDrawEnd,
      onHovering: onHovering,
      onHoveringEnd: onHoveringEnd,
      onStylusButtonChanged: onStylusButtonChanged,
      updatePointerData: updatePointerData,
      undo: undo,
      redo: redo,
      pages: coreInfo.pages,
      initialPageIndex: coreInfo.initialPageIndex,
      pageBuilder: pageBuilder,
      isTextEditing: () => currentTool == Tool.textEditing,
      placeholderPageBuilder: (BuildContext context, int pageIndex) {
        return Canvas(
          path: coreInfo.filePath,
          page: coreInfo.pages[pageIndex],
          pageIndex: 0,
          textEditing: false,
          coreInfo: EditorCoreInfo.placeholder,
          currentStroke: null,
          currentStrokeDetectedShape: null,
          currentSelection: null,
          placeholder: true,
          setAsBackground: null,
          currentTool: currentTool,
          currentScale: double.minPositive,
        );
      },
      transformationController: _transformationController,
    );

    final readonlyBanner = ReadOnlyBanner(
      coreInfo.readOnlyReason,
      action: coreInfo.readOnlyReason == .versionTooNew
          ? showVersionTooNewDialog
          : null,
    );

    final Widget toolbar = Collapsible(
      axis: isToolbarVertical
          ? CollapsibleAxis.horizontal
          : CollapsibleAxis.vertical,
      collapsed:
          DynamicMaterialApp.isFullscreen &&
          !stows.editorToolbarShowInFullscreen.value,
      maintainState: true,
      child: SafeArea(
        bottom: stows.editorToolbarAlignment.value != AxisDirection.up,
        child: Toolbar(
          readOnly: coreInfo.readOnly,
          setTool: (tool) {
            if (tool is Eraser && currentTool is Eraser) {
              // setTool(Eraser) is a special case to toggle the eraser on/off
              tool = _lastNonEraserTool;
            }

            currentTool = tool;

            if (tool is Tape) {
              // there's only one tape
            } else if (tool is Highlighter) {
              Highlighter.currentHighlighter = tool;
            } else if (tool is Pencil) {
              Pencil.currentPencil = tool;
            } else if (tool is Pen) {
              Pen.currentPen = tool;
            }

            if (mounted) setState(() {});
          },
          currentTool: currentTool,
          duplicateSelection: () {
            final select = currentTool as Select;
            if (!select.doneSelecting) return;

            setState(() {
              final page = coreInfo.pages[select.selectResult.pageIndex];
              final strokes = select.selectResult.strokes;
              final images = select.selectResult.images;

              const duplicationFeedbackOffset = Offset(25, -25);

              final duplicatedStrokes = strokes.map((stroke) {
                return stroke.copy()..shift(duplicationFeedbackOffset);
              }).toList();

              final duplicatedImages = images.map((image) {
                return image.copy()
                  ..id = coreInfo.nextImageId++
                  ..dstRect.shift(duplicationFeedbackOffset);
              }).toList();
              duplicatedImages.forEach(_listenToImage);

              page.strokes.addAll(duplicatedStrokes);
              page.images.addAll(duplicatedImages);

              select.selectResult = select.selectResult.copyWith(
                strokes: duplicatedStrokes,
                images: duplicatedImages,
                path: select.selectResult.path.shift(duplicationFeedbackOffset),
              );

              history.recordChange(
                EditorHistoryItem(
                  type: .draw,
                  pageIndex: select.selectResult.pageIndex,
                  strokes: duplicatedStrokes,
                  images: duplicatedImages,
                ),
              );
              autosaveAfterDelay();
            });
          },
          deleteSelection: () {
            final select = currentTool as Select;
            if (!select.doneSelecting) {
              return;
            }

            setState(() {
              final page = coreInfo.pages[select.selectResult.pageIndex];
              final strokes = select.selectResult.strokes;
              final images = select.selectResult.images;

              for (final stroke in strokes) {
                page.strokes.remove(stroke);
              }
              for (final image in images) {
                page.images.remove(image);
              }

              select.unselect();

              history.recordChange(
                EditorHistoryItem(
                  type: .erase,
                  pageIndex: strokes.first.pageIndex,
                  strokes: strokes,
                  images: images,
                ),
              );
              autosaveAfterDelay();
            });
          },
          setColor: (color) {
            setState(() {
              updateColorBar(color);

              if (currentTool is Highlighter) {
                (currentTool as Highlighter).color = color.withAlpha(
                  Highlighter.alpha,
                );
              } else if (currentTool is Pen) {
                (currentTool as Pen).color = color;
              } else if (currentTool is Select) {
                // Changes color of selected strokes
                final select = currentTool as Select;
                if (select.doneSelecting) {
                  final strokes = select.selectResult.strokes;

                  final colorChange = <Stroke, Change<Color>>{};
                  for (final stroke in strokes) {
                    colorChange[stroke] = Change(
                      previous: stroke.color,
                      current: color,
                    );
                    stroke.color = color;
                  }

                  history.recordChange(
                    EditorHistoryItem(
                      type: .changeColor,
                      pageIndex: strokes.first.pageIndex,
                      strokes: strokes,
                      colorChange: colorChange,
                      images: [],
                    ),
                  );
                  autosaveAfterDelay();
                }
              }
            });
          },
          quillFocus: quillFocus,
          textEditing: currentTool == Tool.textEditing,
          toggleTextEditing: () => setState(() {
            if (currentTool == Tool.textEditing) {
              currentTool = Pen.currentPen;
              for (final page in coreInfo.pages) {
                // unselect text, but maintain cursor position
                page.quill.controller.moveCursorToPosition(
                  page.quill.controller.selection.extentOffset,
                );
                page.quill.focusNode.unfocus();
              }
            } else {
              currentTool = Tool.textEditing;
              quillFocus.value = coreInfo.pages[currentPageIndex].quill
                ..focusNode.requestFocus();
            }
          }),
          undo: undo,
          isUndoPossible: history.canUndo,
          redo: redo,
          isRedoPossible: history.canRedo,
          toggleFingerDrawing: () {
            stows.editorFingerDrawing.value = !stows.editorFingerDrawing.value;
            lastSeenPointerCount = 0;
          },
          pickPhoto: _pickPhotos,
          paste: paste,
          exportAsSba: exportAsSba,
          exportAsPdf: exportAsPdf,
          exportAsPng: exportAsPng,
        ),
      ),
    );

    final Widget body;
    if (isToolbarVertical) {
      body = Row(
        textDirection: stows.editorToolbarAlignment.value == AxisDirection.left
            ? .ltr
            : .rtl,
        children: [
          toolbar,
          Expanded(
            child: Column(
              children: [
                Expanded(child: canvas),
                readonlyBanner,
              ],
            ),
          ),
        ],
      );
    } else {
      body = Column(
        verticalDirection:
            stows.editorToolbarAlignment.value == AxisDirection.up
            ? VerticalDirection.up
            : VerticalDirection.down,
        children: [
          Expanded(child: canvas),
          toolbar,
          readonlyBanner,
        ],
      );
    }

    // The page thumbnails slide over the note rather than squeezing it.
    final showPagePanel =
        stows.editorPagePanel.value && !DynamicMaterialApp.isFullscreen;
    final Widget bodyWithPagePanel = Stack(
      children: [
        Positioned.fill(child: body),
        if (showPagePanel)
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            child: EditorPagePanel(
              coreInfo: coreInfo,
              onEditBookmark: _editBookmark,
              transformationController: _transformationController,
              // the page that fills the top of the screen, even
              // when its top edge is just below the toolbar
              getCurrentPageIndex: () => CanvasGestureDetector.horizontalPaging
                  ? currentPageIndex
                  : getPageIndexFromScrollPosition(
                      scrollY: -scrollY + 100,
                      screenWidth: MediaQuery.sizeOf(context).width,
                      pages: coreInfo.pages,
                    ),
              onPageTap: (pageIndex) => CanvasGestureDetector.scrollToPage(
                pageIndex: pageIndex,
                pages: coreInfo.pages,
                screenWidth: MediaQuery.sizeOf(context).width,
                transformationController: _transformationController,
              ),
            ),
          ),
      ],
    );

    return ValueListenableBuilder(
      valueListenable: savingState,
      builder: (context, savingState, child) {
        // don't allow user to go back until saving is done
        return PopScope(
          canPop: savingState == .saved,
          onPopInvokedWithResult: (didPop, _) {
            // The editor can be closed without the user going back, e.g.
            // when their session ends and the app returns to the sign in
            // page. The note is then saved as the editor is disposed.
            if (didPop) return;
            switch (savingState) {
              case .waitingToSave:
                saveToFile(); // trigger save now
                snackBarNeedsToSaveBeforeExiting();
              case .saving:
                snackBarNeedsToSaveBeforeExiting();
              case .saved:
                break;
            }
          },
          child: child!,
        );
      },
      child: Scaffold(
        appBar: DynamicMaterialApp.isFullscreen
            ? null
            : AppBar(
                toolbarHeight: kToolbarHeight,
                bottom: _showTabs
                    ? EditorTabBar(currentPath: coreInfo.filePath)
                    : null,
                title: widget.customTitle != null
                    ? Text(widget.customTitle!)
                    : Form(
                        key: _filenameFormKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: TextFormField(
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                          ),
                          controller: filenameTextEditingController,
                          onChanged: renameFile,
                          autofocus: needsNaming,
                          validator: _validateFilenameTextField,
                        ),
                      ),
                leading: SaveIndicator(
                  savingState: savingState,
                  triggerSave: saveToFile,
                ),
                actions: [
                  if (_realtime case final realtime?)
                    ValueListenableBuilder(
                      valueListenable: realtime.state,
                      builder: (context, state, _) => Tooltip(
                        message: switch (state) {
                          .offline => t.editor.realtime.offline,
                          .catchingUp => t.editor.realtime.catchingUp,
                          .live => t.editor.realtime.live,
                        },
                        child: Padding(
                          padding: const .symmetric(horizontal: 8),
                          child: Icon(switch (state) {
                            .offline => Icons.cloud_off,
                            .catchingUp => Icons.cloud_sync,
                            .live => Icons.cloud_done,
                          }, size: 20),
                        ),
                      ),
                    ),
                  ValueListenableBuilder(
                    valueListenable: _presences,
                    builder: (context, presences, _) =>
                        _Collaborators(presences: presences),
                  ),
                  if (_realtime != null)
                    IconButton(
                      icon: const Icon(Icons.person_add_alt_1),
                      tooltip: t.sharing.title,
                      onPressed: () =>
                          ShareDialog.show(context, coreInfo.filePath),
                    ),
                  if (!coreInfo.readOnly)
                    Builder(
                      builder: (context) {
                        final pageIndex = currentPageIndex;
                        final bookmarked =
                            pageIndex < coreInfo.pages.length &&
                            coreInfo.pages[pageIndex].bookmark != null;
                        return IconButton(
                          icon: Icon(
                            bookmarked ? Icons.bookmark : Icons.bookmark_border,
                          ),
                          tooltip: bookmarked
                              ? t.editor.bookmarks.edit
                              : t.editor.bookmarks.add,
                          onPressed: () => bookmarked
                              ? _editBookmark(pageIndex)
                              : _setBookmark(pageIndex, ''),
                        );
                      },
                    ),
                  if (coreInfo.flashcards)
                    IconButton(
                      icon: const Icon(Icons.style),
                      tooltip: t.editor.flashcards.study,
                      onPressed: _study,
                    ),
                  IconButton(
                    icon: Icon(
                      stows.editorPagePanel.value
                          ? Icons.view_sidebar
                          : Icons.view_sidebar_outlined,
                    ),
                    tooltip: t.editor.pagePanel,
                    onPressed: () => setState(() {
                      stows.editorPagePanel.value =
                          !stows.editorPagePanel.value;
                    }),
                  ),
                  IconButton(
                    icon: Icon(
                      CanvasGestureDetector.horizontalPaging
                          ? Icons.view_carousel
                          : Icons.view_day,
                    ),
                    tooltip: CanvasGestureDetector.horizontalPaging
                        ? t.editor.scrollContinuously
                        : t.editor.turnPages,
                    onPressed: _toggleHorizontalPaging,
                  ),
                  IconButton(
                    icon: const AdaptiveIcon(
                      icon: Icons.insert_page_break,
                      cupertinoIcon: CupertinoIcons.add,
                    ),
                    tooltip: t.editor.menu.insertPage,
                    onPressed: () => setState(() {
                      final currentPageIndex = this.currentPageIndex;
                      insertPageAfter(currentPageIndex);
                      CanvasGestureDetector.scrollToPage(
                        pageIndex: currentPageIndex + 1,
                        pages: coreInfo.pages,
                        screenWidth: MediaQuery.sizeOf(context).width,
                        transformationController: _transformationController,
                      );
                    }),
                  ),
                  IconButton(
                    icon: const AdaptiveIcon(
                      icon: Icons.grid_view,
                      cupertinoIcon: CupertinoIcons.rectangle_grid_2x2,
                    ),
                    tooltip: t.editor.pages,
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AdaptiveAlertDialog(
                          title: Text(t.editor.pages),
                          content: pageManager(context),
                          actions: const [],
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const AdaptiveIcon(
                      icon: Icons.more_vert,
                      cupertinoIcon: CupertinoIcons.ellipsis_vertical,
                    ),
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        builder: (context) => bottomSheet(context),
                        isScrollControlled: true,
                        showDragHandle: true,
                        backgroundColor: colorScheme.surface,
                        constraints: const BoxConstraints(maxWidth: 500),
                      );
                    },
                  ),
                ],
              ),
        body: bodyWithPagePanel,
        floatingActionButton:
            (DynamicMaterialApp.isFullscreen &&
                !stows.editorToolbarShowInFullscreen.value)
            ? FloatingActionButton(
                shape: platform.isCupertino ? const CircleBorder() : null,
                onPressed: () {
                  DynamicMaterialApp.setFullscreen(false, updateSystem: true);
                },
                child: const Icon(Icons.fullscreen_exit),
              )
            : null,
      ),
    );
  }

  void snackBarNeedsToSaveBeforeExiting() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t.editor.needsToSaveBeforeExiting)));
  }

  Widget bottomSheet(BuildContext context) {
    final Brightness brightness = Theme.brightnessOf(context);
    final invert = stows.editorAutoInvert.value && brightness == .dark;
    final int currentPageIndex = this.currentPageIndex;

    return EditorBottomSheet(
      invert: invert,
      coreInfo: coreInfo,
      currentPageIndex: currentPageIndex,
      setBackgroundPattern: (pattern) => setState(() {
        if (coreInfo.readOnly) return;
        final previous = coreInfo.backgroundPattern;
        coreInfo.backgroundPattern = pattern;
        stows.lastBackgroundPattern.value = pattern;
        history.recordChange(
          EditorHistoryItem(
            type: .backgroundPattern,
            pageIndex: currentPageIndex,
            backgroundPatternChange: Change(
              previous: previous,
              current: pattern,
            ),
            strokes: [],
            images: [],
          ),
        );
        autosaveAfterDelay();
      }),
      setLineHeight: (lineHeight) => setState(() {
        if (coreInfo.readOnly) return;
        coreInfo.lineHeight = lineHeight;
        stows.lastLineHeight.value = lineHeight;
        autosaveAfterDelay();
      }),
      setLineThickness: (lineThickness) => setState(() {
        if (coreInfo.readOnly) return;
        coreInfo.lineThickness = lineThickness;
        stows.lastLineThickness.value = lineThickness;
        autosaveAfterDelay();
      }),
      removeBackgroundImage: () => setState(() {
        if (coreInfo.readOnly) return;

        final page = coreInfo.pages[currentPageIndex];
        final image = page.backgroundImage;
        if (image == null) return;
        page.images.add(image);
        page.backgroundImage = null;

        _submitImageUpdate(image);
        autosaveAfterDelay();
      }),
      redrawImage: () => setState(() {}),
      clearPage: () {
        clearPage(currentPageIndex);
      },
      clearAllPages: clearAllPages,
      redrawAndSave: () => setState(() {
        if (coreInfo.readOnly) return;
        // e.g. how the background image fits the page
        _submitImageUpdate(coreInfo.pages[currentPageIndex].backgroundImage);
        autosaveAfterDelay();
      }),
      pickPhotos: _pickPhotos,
      importPdf: importPdf,
      canRasterPdf: Editor.canRasterPdf,
      setFlashcards: (flashcards) => setState(() {
        if (coreInfo.readOnly || coreInfo.flashcards == flashcards) return;
        coreInfo.flashcards = flashcards;
        _submitOps([NoteOps.flashcards(coreInfo)]);
        _saveChangeOutsideHistory();
      }),
      getIsWatchingServer: () => _watchServerTimer?.isActive ?? false,
      setIsWatchingServer: (bool watch) {
        if (watch) {
          _watchServerTimer ??= Timer.periodic(
            const Duration(seconds: 5),
            (_) => _refreshCurrentNote(),
          );
          if (coreInfo.readOnlyReason != .watchingServer) {
            assert(coreInfo.readOnlyReason == null);
            coreInfo.readOnlyReason = .watchingServer;
            if (mounted) setState(() {});
          }
        } else {
          _watchServerTimer?.cancel();
          _watchServerTimer = null;
          if (coreInfo.readOnlyReason == .watchingServer) {
            coreInfo.readOnlyReason = null;
            if (mounted) setState(() {});
          }
        }
      },
    );
  }

  Widget pageBuilder(BuildContext context, int pageIndex) {
    final page = coreInfo.pages[pageIndex];
    final currentStroke = Pen.currentStroke?.pageIndex == pageIndex
        ? Pen.currentStroke
        : null;
    return Canvas(
      path: coreInfo.filePath,
      page: page,
      pageIndex: pageIndex,
      textEditing: currentTool == Tool.textEditing,
      coreInfo: coreInfo,
      currentStroke: currentStroke,
      currentStrokeDetectedShape:
          currentTool is ShapePen && currentStroke != null
          ? ShapePen.detectedShape
          : null,
      currentSelection: () {
        if (currentTool is! Select) return null;
        final selectResult = (currentTool as Select).selectResult;
        if (selectResult.pageIndex != pageIndex) return null;
        return selectResult;
      }(),
      setAsBackground: (EditorImage image) {
        final previous = page.backgroundImage;
        if (previous != null) {
          // restore previous background image as normal image
          page.images.add(previous);
        }
        page.images.remove(image);
        page.backgroundImage = image;
        _submitImageUpdate(image);
        _submitImageUpdate(previous);

        CanvasImage.activeListener
            .notifyListenersPlease(); // un-select active image

        autosaveAfterDelay();
        setState(() {});
      },
      currentTool: currentTool,
      currentScale: _transformationController.value.approxScale,
      overlay: ValueListenableBuilder(
        valueListenable: _presences,
        builder: (context, presences, _) => RemoteCursors(
          // how big the page is on screen, zoom and fitting included
          scale: switch (page.renderBox) {
            final box? when box.attached =>
              (box.localToGlobal(const Offset(100, 0)) -
                          box.localToGlobal(Offset.zero))
                      .distance /
                  100,
            _ => _transformationController.value.approxScale,
          },
          cursors: [
            for (final MapEntry(key: from, value: presence)
                in presences.entries)
              if (presence.pageId == page.id)
                RemoteCursor(
                  user: presence.user,
                  position: presence.position,
                  color: RemoteCursor.colorOf(from),
                  down: presence.down,
                ),
          ],
        ),
      ),
    );
  }

  Widget pageManager(BuildContext context) {
    return EditorPageManager(
      coreInfo: coreInfo,
      currentPageIndex: currentPageIndex,
      redrawAndSave: () => setState(() {
        if (coreInfo.readOnly) return;
        autosaveAfterDelay();
      }),
      insertPageAfter: insertPageAfter,
      duplicatePage: (int pageIndex) => setState(() {
        if (coreInfo.readOnly) return;
        final page = coreInfo.pages[pageIndex];
        final newPage = page.copyWith(
          strokes: page.strokes
              .map((stroke) => stroke.copy()..pageIndex += 1)
              .toList(),
          images: page.images
              .map((image) => image.copy()..pageIndex += 1)
              .toList(),
          quill: QuillStruct(
            controller: flutter_quill.QuillController(
              document: flutter_quill.Document.fromDelta(
                page.quill.controller.document.toDelta(),
              ),
              selection: const TextSelection.collapsed(offset: 0),
            ),
            focusNode: FocusNode(debugLabel: 'Quill Focus Node'),
          ),
          backgroundImage: page.backgroundImage?.copy()?..pageIndex += 1,
        )..id = newId();
        if (newPage.backgroundImage case final image?) _listenToImage(image);
        newPage.images.forEach(_listenToImage);
        coreInfo.pages.insert(pageIndex + 1, newPage);
        listenToQuillChanges(newPage.quill, pageIndex + 1);
        history.recordChange(
          EditorHistoryItem(
            type: .insertPage,
            pageIndex: pageIndex,
            strokes: const [],
            images: const [],
            page: newPage,
          ),
        );
        autosaveAfterDelay();
      }),
      clearPage: clearPage,
      deletePage: (int pageIndex) => setState(() {
        if (coreInfo.readOnly) return;
        final page = coreInfo.pages.removeAt(pageIndex);
        createPage(pageIndex - 1);
        history.recordChange(
          EditorHistoryItem(
            type: .deletePage,
            pageIndex: pageIndex,
            strokes: const [],
            images: const [],
            page: page,
          ),
        );
        autosaveAfterDelay();
      }),
      movePage: movePage,
      transformationController: _transformationController,
    );
  }

  /// Moves the page at [oldIndex] so that it ends up at [newIndex].
  void movePage(int oldIndex, int newIndex) => setState(() {
    if (coreInfo.readOnly) return;
    final pages = coreInfo.pages;
    // the blank page at the end stays at the end
    final lastIndex = pages.length - 1;
    if (oldIndex == lastIndex && pages[lastIndex].isEmpty) return;
    if (newIndex >= lastIndex && pages[lastIndex].isEmpty) {
      newIndex = lastIndex - 1;
    }
    if (oldIndex == newIndex) return;

    final page = pages.removeAt(oldIndex);
    pages.insert(newIndex, page);
    for (int i = min(oldIndex, newIndex); i < pages.length; i++) {
      pages[i].updatePageIndex(i);
    }
    _submitOps([
      NoteOps.movePage(
        page,
        afterPageId: newIndex > 0 ? pages[newIndex - 1].id : null,
      ),
    ]);
    _saveChangeOutsideHistory();
  });

  void insertPageAfter(int pageIndex) => setState(() {
    if (coreInfo.readOnly) return;
    final page = EditorPage(id: newId());
    coreInfo.pages.insert(pageIndex + 1, page);
    listenToQuillChanges(page.quill, pageIndex + 1);
    history.recordChange(
      EditorHistoryItem(
        type: .insertPage,
        pageIndex: pageIndex + 1,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
    autosaveAfterDelay();
  });

  void clearPage(int pageIndex) {
    if (coreInfo.readOnly) return;
    final page = coreInfo.pages[pageIndex];
    setState(() {
      final removedStrokes = page.strokes.toList();
      final removedImages = page.images.toList();
      page.strokes.clear();
      page.images.clear();
      removeExcessPages();
      history.recordChange(
        EditorHistoryItem(
          type: .erase,
          pageIndex: pageIndex,
          strokes: removedStrokes,
          images: removedImages,
        ),
      );
      autosaveAfterDelay();
    });
  }

  void clearAllPages() {
    if (coreInfo.readOnly) return;
    setState(() {
      final removedStrokes = <Stroke>[];
      final removedImages = <EditorImage>[];
      for (final page in coreInfo.pages) {
        removedStrokes.addAll(page.strokes);
        removedImages.addAll(page.images);
        page.strokes.clear();
        page.images.clear();
      }
      removeExcessPages();
      history.recordChange(
        EditorHistoryItem(
          type: .erase,
          pageIndex: 0,
          strokes: removedStrokes,
          images: removedImages,
        ),
      );
    });
    autosaveAfterDelay();
  }

  Future<void> showVersionTooNewDialog() async {
    final disableReadOnly =
        await showDialog(
          context: context,
          builder: (context) => AdaptiveAlertDialog(
            title: Text(t.editor.versionTooNew.title),
            content: Text(t.editor.versionTooNew.subtitle),
            actions: [
              CupertinoDialogAction(
                child: Text(t.common.cancel),
                onPressed: () => Navigator.pop(context, false),
              ),
              CupertinoDialogAction(
                child: Text(t.editor.versionTooNew.allowEditing),
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted) return;
    if (!disableReadOnly) return;

    if (coreInfo.readOnlyReason == .versionTooNew) {
      coreInfo.readOnlyReason = null;
      if (mounted) setState(() {});
    }
  }

  late int _lastCurrentPageIndex = coreInfo.initialPageIndex ?? 0;

  /// The index of the page that is currently centered on screen.
  int get currentPageIndex {
    if (!mounted) return _lastCurrentPageIndex;

    final screenWidth = MediaQuery.sizeOf(context).width;

    if (CanvasGestureDetector.horizontalPaging) {
      return _lastCurrentPageIndex = CanvasGestureDetector.horizontalPageIndex(
        transform: _transformationController.value,
        screenWidth: screenWidth,
        pageCount: coreInfo.pages.length,
      );
    }

    return _lastCurrentPageIndex = getPageIndexFromScrollPosition(
      scrollY: -scrollY,
      screenWidth: screenWidth,
      pages: coreInfo.pages,
    );
  }

  @visibleForTesting
  static int getPageIndexFromScrollPosition({
    required double scrollY,
    required double screenWidth,
    required List<EditorPage> pages,
  }) {
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final bottomOfPage = CanvasGestureDetector.getTopOfPage(
        pageIndex: pageIndex + 1, // top of next page
        pages: pages,
        screenWidth: screenWidth,
      );

      if (scrollY < bottomOfPage) {
        return pageIndex;
      }
    }
    // below the last page
    return pages.length - 1;
  }

  @override
  void dispose() {
    unawaited(_cleanUpAsync());

    DynamicMaterialApp.removeFullscreenListener(_setState);
    stows.openTabs.removeListener(_setState);

    _delayedSaveTimer?.cancel();
    _watchServerTimer?.cancel();
    _lastSeenPointerCountTimer?.cancel();
    _noteTextChanges();
    _syncedPathWhenClosed = _realtime?.room;
    _realtime?.sendPresence(null);
    _realtime?.dispose();
    _presenceCleanupTimer?.cancel();

    _removeKeybindings();

    // manually save pen properties since the listeners don't fire if a property is changed
    stows.lastFountainPenOptions.notifyListeners();
    stows.lastBallpointPenOptions.notifyListeners();
    stows.lastHighlighterOptions.notifyListeners();
    stows.lastPencilOptions.notifyListeners();
    stows.lastShapePenOptions.notifyListeners();

    super.dispose();
  }

  Future<void> _cleanUpAsync() async {
    try {
      if (_renameTimer?.isActive ?? false) {
        _renameTimer!.cancel();
        await _renameFileNow();
        filenameTextEditingController.dispose();
      }
      await saveToFile();
    } finally {
      // the note is in the hands of the library syncer from now on
      if (_pathOpenForSync case final path?) {
        final isUpToDate =
            _syncedPathWhenClosed == coreInfo.filePath &&
            coreInfo.pendingOps.isEmpty;
        AccountSyncer.instance.noteClosed(
          path,
          closedPath: coreInfo.filePath,
          seq: isUpToDate ? coreInfo.realtimeSeq : null,
        );
      }
      coreInfo.dispose();
    }
  }
}

/// Where another person who has the note open was last seen.
typedef _Presence = ({
  String user,
  String pageId,
  Offset position,
  bool down,
  DateTime seen,
});

/// The people who have the note open on other devices, as small avatars.
class _Collaborators extends StatelessWidget {
  const new({required this.presences});

  final Map<String, _Presence> presences;

  @override
  Widget build(BuildContext context) {
    final users = <String, Color>{};
    for (final MapEntry(key: from, value: presence) in presences.entries) {
      users.putIfAbsent(presence.user, () => RemoteCursor.colorOf(from));
    }
    if (users.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: '${t.sharing.collaborators} : ${users.keys.join(', ')}',
      child: Padding(
        padding: const .symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: .min,
          children: [
            for (final MapEntry(key: user, value: color) in users.entries.take(
              4,
            ))
              Align(
                widthFactor: 0.75,
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: Colors.white,
                  child: CircleAvatar(
                    radius: 12,
                    backgroundColor: color,
                    child: Text(
                      user.isEmpty ? '?' : user.characters.first.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: .w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
