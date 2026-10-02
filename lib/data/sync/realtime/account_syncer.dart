import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/data/sync/realtime/realtime_account.dart';
import 'package:saber/data/sync/realtime/realtime_session.dart';
import 'package:saber/pages/editor/editor.dart';

enum AccountSyncState {
  /// The user isn't signed in to an account.
  signedOut,

  /// The library is being compared with the account's.
  syncing,

  /// The library is the same as the account's.
  upToDate,

  /// The server couldn't be reached. We'll try again soon.
  offline,
}

/// Keeps the notes that aren't open in sync with the user's account, so that
/// every device of the account has the same library.
///
/// The note that is open in the editor is synced by the editor instead.
class AccountSyncer {
  new({
    this.pollInterval = const Duration(seconds: 5),
    this.noteTimeout = const Duration(seconds: 30),
  });

  static final log = Logger('AccountSyncer');

  /// The syncer of the app. It does nothing until [start] is called.
  static final instance = AccountSyncer();

  /// How often to ask the server which notes the account has.
  final Duration pollInterval;

  /// How long a note may take to sync before we move on to the next one.
  final Duration noteTimeout;

  final state = ValueNotifier(AccountSyncState.signedOut);

  /// The paths of the notes that are open in an editor.
  final _openNotes = <String>{};

  Timer? _timer;
  Future<void>? _currentSync;
  var _syncAgain = false;

  /// Starts syncing now, and whenever something might have changed.
  Future<void> start() async {
    await RealtimeAccount.waitUntilLoaded();
    FileManager.onNoteRemoved = _onNoteRemoved;
    stows.realtimeToken.addListener(syncNow);
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => syncNow());
    unawaited(syncNow());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    stows.realtimeToken.removeListener(syncNow);
    if (FileManager.onNoteRemoved == _onNoteRemoved) {
      FileManager.onNoteRemoved = null;
    }
  }

  /// Call this when a note is opened in an editor,
  /// so that it's left alone until [noteClosed] is called.
  void noteOpened(String path) => _openNotes.add(path);

  /// Call this when the note that was opened as [path] has been closed and
  /// saved at [closedPath], which differs from [path] if it was renamed.
  ///
  /// [seq] is the sequence number of the last operation in the saved note,
  /// or null if the note has changes that the server doesn't have yet.
  void noteClosed(String path, {String? closedPath, int? seq}) {
    _openNotes.remove(path);
    if (closedPath != null) _setSeq(closedPath, seq);
  }

  bool _isOpen(String path) => _openNotes.contains(path);

  Map<String, int> get _seqs {
    try {
      return (jsonDecode(stows.realtimeNoteSeqs.value) as Map).cast();
    } catch (e) {
      return {};
    }
  }

  void _setSeq(String path, int? seq) {
    final seqs = _seqs;
    if (seqs[path] == seq) return;
    if (seq == null) {
      seqs.remove(path);
    } else {
      seqs[path] = seq;
    }
    stows.realtimeNoteSeqs.value = jsonEncode(seqs);
  }

  void _onNoteRemoved(String path) {
    if (!RealtimeAccount.isSignedIn) return;
    _setSeq(path, null);
    final pending = stows.realtimePendingDeletes.value;
    if (!pending.contains(path)) {
      stows.realtimePendingDeletes.value = [...pending, path];
    }
    unawaited(syncNow());
  }

  static bool _noteExists(String path) =>
      FileManager.doesFileExist(path + Editor.extension) ||
      FileManager.doesFileExist(path + Editor.extensionOldJson);

  /// Compares the library with the account's as soon as possible.
  ///
  /// The returned future completes when the library has been synced.
  Future<void> syncNow() {
    if (_currentSync != null) {
      _syncAgain = true;
      return _currentSync!;
    }
    return _currentSync = () async {
      try {
        do {
          _syncAgain = false;
          await _sync();
        } while (_syncAgain);
      } finally {
        _currentSync = null;
      }
    }();
  }

  Future<void> _sync() async {
    if (!RealtimeAccount.isSignedIn) {
      state.value = .signedOut;
      return;
    }
    if (state.value != .upToDate) state.value = .syncing;

    try {
      await _sendPendingDeletes();
      final remote = await RealtimeAccount.fetchNotes();
      final pendingDeletes = stows.realtimePendingDeletes.value.toSet();
      final local = (await FileManager.getAllFiles()).toSet();

      // notes that were deleted on another device
      for (final path in remote.deleted) {
        if (pendingDeletes.contains(path) || _isOpen(path)) continue;
        if (!_noteExists(path)) {
          _setSeq(path, null);
          continue;
        }
        state.value = .syncing;
        await _deleteOrShareAgain(path);
      }

      // notes that were created or changed on another device
      for (final MapEntry(key: path, value: head) in remote.heads.entries) {
        if (pendingDeletes.contains(path) || _isOpen(path)) continue;
        final exists = _noteExists(path);
        if (exists && (_seqs[path] ?? -1) >= head) continue;
        state.value = .syncing;
        await _syncNote(path, exists: exists);
      }

      // notes that the account doesn't have yet
      for (final path in local) {
        if (remote.heads.containsKey(path) || remote.deleted.contains(path)) {
          continue;
        }
        if (_isOpen(path) || _seqs.containsKey(path)) continue;
        state.value = .syncing;
        await _syncNote(path, exists: true);
      }

      state.value = .upToDate;
    } on RealtimeAccountException catch (e) {
      log.info('Failed to sync the library: $e');
      state.value = RealtimeAccount.isSignedIn ? .offline : .signedOut;
    } catch (e, st) {
      log.severe('Failed to sync the library: $e', e, st);
      state.value = .offline;
    }
  }

  /// Tells the server about the notes that were deleted on this device.
  Future<void> _sendPendingDeletes() async {
    for (final path in stows.realtimePendingDeletes.value) {
      // If there's a note at this path again, the account should keep it.
      if (!_noteExists(path)) await RealtimeAccount.deleteNote(path);
      stows.realtimePendingDeletes.value = [
        for (final pending in stows.realtimePendingDeletes.value)
          if (pending != path) pending,
      ];
    }
  }

  /// Handles the note at [path] having been deleted on another device.
  Future<void> _deleteOrShareAgain(String path) async {
    final coreInfo = await EditorCoreInfo.loadFromFilePath(path);
    final wasSynced = coreInfo.realtimeSeq != null;
    final hasUnsentChanges = coreInfo.pendingOps.isNotEmpty;
    final readOnly = coreInfo.readOnly;
    coreInfo.dispose();
    if (readOnly || _isOpen(path)) return;

    if (wasSynced && !hasUnsentChanges) {
      log.info('Deleting $path, which was deleted on another device');
      for (final extension in [Editor.extension, Editor.extensionOldJson]) {
        // [alsoUpload] is false because the account already knows
        await FileManager.deleteFile(path + extension, alsoUpload: false);
      }
      _setSeq(path, null);
    } else {
      // This is another note that took the name of the deleted one,
      // or the note was changed here after it was deleted over there.
      await _syncNote(path, exists: true, asNewNote: true);
    }
  }

  /// Brings the note at [path] up to date with the account, without an editor.
  ///
  /// [exists] is whether this device has the note already.
  /// If [asNewNote] is true, the note is shared as if it had never been synced.
  Future<void> _syncNote(
    String path, {
    required bool exists,
    bool asNewNote = false,
  }) async {
    if (_isOpen(path)) return;

    final coreInfo = await EditorCoreInfo.loadFromFilePath(path);
    // If we don't have the note yet, everything
    // in it is on the server, so there's nothing to share.
    if (!exists) coreInfo.realtimeSeq = 0;
    try {
      if (coreInfo.readOnly) {
        log.warning('Not syncing $path: ${coreInfo.readOnlyReason}');
        return;
      }
      if (asNewNote) {
        coreInfo
          ..realtimeSeq = null
          ..pendingOps.clear();
      }

      final pages = coreInfo.pages;
      void createPage(int pageIndex) {
        while (pageIndex >= pages.length - 1) {
          pages.add(EditorPage());
          coreInfo.assignPageIds();
        }
      }

      void removeExcessPages() {
        for (int i = pages.length - 1; i >= 1; --i) {
          if (pages[i].isNotEmpty || pages[i - 1].isNotEmpty) break;
          pages.removeAt(i).dispose();
        }
      }

      if (coreInfo.isEmpty) createPage(-1);

      var changed = !exists || asNewNote;
      final token = stows.realtimeToken.value;
      final session = RealtimeSession(
        serverUrl: RealtimeAccount.webSocketUrl,
        token: token,
        room: path,
        clientId: stows.realtimeClientId.value,
        applier: NoteOpApplier(
          coreInfo: coreInfo,
          createPage: createPage,
          removeExcessPages: removeExcessPages,
        ),
        onRemoteChange: () => changed = true,
        onLocalStateChange: () => changed = true,
        onStopped: (reason) {
          if (reason == .unauthorized) RealtimeAccount.sessionEnded(token);
        },
      )..start();

      final stopwatch = Stopwatch()..start();
      bool isSynced() =>
          session.state.value == .live && coreInfo.pendingOps.isEmpty;
      while (!isSynced() &&
          session.stopReason == null &&
          stopwatch.elapsed < noteTimeout &&
          !_isOpen(path)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final synced = isSynced();
      final stopReason = session.stopReason;
      session.dispose();

      // The editor has its own copy of the note now, and saves it itself.
      if (_isOpen(path)) return;
      // We'll be told that it was deleted the next time we list the notes.
      if (stopReason == .deleted) return;
      if (stopReason == .unauthorized) {
        throw const RealtimeAccountException(
          RealtimeAccountException.unauthorized,
        );
      }

      if (changed) await _save(coreInfo);
      if (synced) {
        _setSeq(path, coreInfo.realtimeSeq);
      } else {
        log.info('Timed out syncing $path');
      }
    } finally {
      coreInfo.dispose();
    }
  }

  /// Saves [coreInfo] like the editor does.
  static Future<void> _save(EditorCoreInfo coreInfo) async {
    final filePath = coreInfo.filePath + Editor.extension;
    final Uint8List bson;
    final OrderedAssetCache assets;
    coreInfo.assetCache.allowRemovingAssets = false;
    try {
      (bson, assets) = coreInfo.saveToBinary(currentPageIndex: null);
    } finally {
      coreInfo.assetCache.allowRemovingAssets = true;
    }
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
  }
}
