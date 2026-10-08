import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bson/bson.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';

enum RealtimeState {
  /// Not connected to the server. Changes are queued until we reconnect.
  offline,

  /// Connected, and catching up on the changes made by other devices.
  catchingUp,

  /// Changes are being sent and received as they happen.
  live,
}

/// Why a [RealtimeSession] gave up on syncing its note.
enum RealtimeStopReason {
  /// The server doesn't accept our session, so the user must sign in again.
  unauthorized,

  /// The note was deleted on another device.
  deleted,
}

/// Keeps one note in sync with the account's other devices that have it open,
/// by exchanging [NoteOp]s through the account's server.
///
/// The server gives each operation a sequence number, and every device
/// applies the operations in that order.
class RealtimeSession {
  new({
    required this.serverUrl,
    required this.token,
    required this.room,
    required this.clientId,
    required this.applier,
    required this.onRemoteChange,
    required this.onLocalStateChange,
    this.onStopped,
    this.share,
    this.onPresence,
    this.minReconnectDelay = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 30),
  });

  static final log = Logger('RealtimeSession');

  /// The account's server, e.g. `ws://192.168.1.10:8787`.
  final String serverUrl;

  /// The session that the server gave this device when the user signed in.
  final String token;

  /// The path of the note, which is how the account's devices
  /// know that they have the same note.
  final String room;

  /// Identifies this device among the others of the account.
  final String clientId;

  /// The token of the link that the note was opened with,
  /// if it's another account's note. [room] is then ignored by the server.
  final String? share;

  /// Called when another device says where its user is in the note,
  /// with null [presence] when it leaves.
  final void Function(String from, String user, Map<String, dynamic>? presence)?
  onPresence;

  final NoteOpApplier applier;
  EditorCoreInfo get coreInfo => applier.coreInfo;

  /// Called after an operation from another device has changed the note.
  final VoidCallback onRemoteChange;

  /// Called when [EditorCoreInfo.realtimeSeq] or
  /// [EditorCoreInfo.pendingOps] change, i.e. the note needs saving.
  final VoidCallback onLocalStateChange;

  /// Called when this session gives up on syncing the note.
  final void Function(RealtimeStopReason reason)? onStopped;

  final Duration minReconnectDelay, maxReconnectDelay;

  final state = ValueNotifier(RealtimeState.offline);

  WebSocket? _socket;
  Timer? _reconnectTimer;
  var _reconnectAttempts = 0;
  var _disposed = false;

  /// Why this session won't reconnect, if it won't.
  RealtimeStopReason? get stopReason => _stopReason;
  RealtimeStopReason? _stopReason;

  /// Whether this note had never been synced when we joined the room,
  /// so its existing contents need to be sent once we've caught up.
  var _needsSnapshot = false;

  static var _lastOpId = 0;

  /// Returns an id that increases with each operation from this device,
  /// including across restarts of the app.
  static int _newOpId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return _lastOpId = max(now, _lastOpId + 1);
  }

  void start() {
    if (_disposed || _stopReason != null) return;
    unawaited(_connect());
  }

  /// Queues [ops] to be sent to the other devices.
  void submit(List<NoteOp> ops) {
    if (ops.isEmpty) return;

    // A note that has never been synced is sent as a whole when we first
    // catch up, so we don't need to track its individual changes until then.
    if (coreInfo.realtimeSeq == null && state.value != .live) return;

    for (final op in ops) {
      if (state.value != .live) _dropSupersededText(coreInfo, op);
      final envelope = <String, dynamic>{'cid': _newOpId(), 'd': op};
      coreInfo.pendingOps.add(envelope);
      _sendIfReady(envelope);
    }
    onLocalStateChange();
  }

  /// Call this when the text of [page] may have changed on this device,
  /// to send the change to the other devices.
  void textChanged(EditorPage page) {
    final envelope = _queueTextChange(coreInfo, page);
    if (envelope == null) return;
    _sendIfReady(envelope);
    onLocalStateChange();
  }

  /// Same as [textChanged], for a note that has no session:
  /// the change is sent the next time the note is synced.
  static void textChangedWithoutSession(
    EditorCoreInfo coreInfo,
    EditorPage page,
  ) => _queueTextChange(coreInfo, page);

  static bool _isTextOp(Map<dynamic, dynamic> op) =>
      op['t'] == NoteOps.textType || op['t'] == NoteOps.textDeltaType;

  /// The pending operations that change the text of the page with id
  /// [pageId], oldest first.
  static Iterable<Map<String, dynamic>> _pendingTextOps(
    EditorCoreInfo coreInfo,
    String pageId,
  ) => coreInfo.pendingOps.where((pending) {
    final op = pending['d'] as Map;
    return _isTextOp(op) && op['pg'] == pageId;
  });

  /// Queues how the text of [page] has changed since its last operation.
  ///
  /// Returns the envelope of the new operation, or null if there was no
  /// change or it was merged into an operation that hasn't been sent yet.
  static Map<String, dynamic>? _queueTextChange(
    EditorCoreInfo coreInfo,
    EditorPage page,
  ) {
    final op = NoteOps.textChange(page, base: coreInfo.realtimeSeq ?? 0);
    if (op == null) return null;
    // A note that has never been synced is sent as a whole.
    if (coreInfo.realtimeSeq == null) return null;

    // The changes to a text are sent one at a time (see [_sendIfReady]),
    // so those made while one is on its way are sent together.
    final last = _pendingTextOps(coreInfo, page.id).lastOrNull;
    if (last != null && last['sent'] != true) {
      final lastOp = last['d'] as Map;
      if (lastOp['t'] == NoteOps.textDeltaType) {
        lastOp['d'] = Delta.fromJson(lastOp['d'] as List)
            .compose(Delta.fromJson(op['d'] as List))
            .toJson();
        return null;
      }
    }

    final envelope = <String, dynamic>{'cid': _newOpId(), 'd': op};
    coreInfo.pendingOps.add(envelope);
    return envelope;
  }

  /// Sends the pending operation in [envelope] if we're connected.
  ///
  /// A change to the text of a page waits until the server has acknowledged
  /// the previous change to that text, because the server merges each change
  /// with those of other devices, and assumes that it follows our last one.
  void _sendIfReady(Map<String, dynamic> envelope) {
    if (state.value != .live) return;
    final op = envelope['d'] as Map;
    if (_isTextOp(op)) {
      final first = _pendingTextOps(coreInfo, op['pg'] as String).firstOrNull;
      if (!identical(first, envelope)) return;
    }
    envelope['sent'] = true;
    _send({'k': 'op', 'cid': envelope['cid'], 'd': op});
  }

  /// Sends the next change to the text of the page with id [pageId],
  /// now that the previous one has been acknowledged.
  void _sendNextTextOp(String pageId) {
    final next = _pendingTextOps(coreInfo, pageId).firstOrNull;
    if (next != null) _sendIfReady(next);
  }

  /// A page's text is sent whole, so while we're offline only
  /// the last version of it needs to be kept in the queue.
  static void _dropSupersededText(EditorCoreInfo coreInfo, NoteOp op) {
    if (op['t'] != NoteOps.textType) return;
    coreInfo.pendingOps.removeWhere((pending) {
      final queued = pending['d'] as Map;
      return queued['t'] == NoteOps.textType && queued['pg'] == op['pg'];
    });
  }

  /// Queues [ops] in [coreInfo] to be sent the next time it's synced,
  /// for changes that are made while the note has no session.
  static void queueForLater(EditorCoreInfo coreInfo, List<NoteOp> ops) {
    // A note that has never been synced is sent as a whole.
    if (coreInfo.realtimeSeq == null) return;
    for (final op in ops) {
      _dropSupersededText(coreInfo, op);
      coreInfo.pendingOps.add({'cid': _newOpId(), 'd': op});
    }
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    if (_disposed || _stopReason != null) return;

    final WebSocket socket;
    try {
      socket = await WebSocket.connect(serverUrl)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      log.info('Failed to connect to $serverUrl: $e');
      _scheduleReconnect();
      return;
    }
    if (_disposed || _stopReason != null) {
      unawaited(socket.close());
      return;
    }

    _socket = socket;
    socket.pingInterval = const Duration(seconds: 20);
    state.value = .catchingUp;
    _needsSnapshot = coreInfo.realtimeSeq == null;
    applier.addedStrokeIds.clear();
    applier.addedImageIds.clear();

    socket.listen(
      (data) => _onMessage(socket, data),
      onDone: () => _onDisconnected(socket),
      onError: (Object e) {
        log.info('Socket error: $e');
        _onDisconnected(socket);
      },
      cancelOnError: true,
    );

    _send({
      'k': 'join',
      'room': room,
      'since': coreInfo.realtimeSeq ?? 0,
      'client': clientId,
      'token': token,
      'share': ?share,
      // a note that has never been synced replaces a deleted one of its name
      'create': coreInfo.realtimeSeq == null,
    });
  }

  void _onMessage(WebSocket socket, dynamic data) {
    if (socket != _socket || _disposed) return;
    if (data is! List<int>) return;

    final Map<String, dynamic> message;
    try {
      message = BsonCodec.deserialize(
        BsonBinary.from(data is Uint8List ? data : Uint8List.fromList(data)),
      );
    } catch (e, st) {
      log.severe('Failed to decode message: $e', e, st);
      return;
    }

    switch (message['k']) {
      case 'op':
        _onRemoteOp(message);
      case 'ack':
        _advanceSeq(opInt(message['seq']));
        _removePending(opInt(message['cid']));
        onLocalStateChange();
      case 'synced':
        _onSynced(opInt(message['head']));
      case 'presence':
        onPresence?.call(
          message['from'] as String? ?? '',
          message['user'] as String? ?? '',
          (message['d'] as Map?)?.cast<String, dynamic>(),
        );
      case 'deleted':
        _stop(.deleted);
      case 'error':
        log.severe('Server error: ${message['message']}');
        if (message['code'] == 'auth') _stop(.unauthorized);
      default:
        log.warning('Unknown message kind: ${message['k']}');
    }
  }

  void _onRemoteOp(Map<String, dynamic> message) {
    final seq = opInt(message['seq']);
    final cid = opInt(message['cid']);
    final op = Map<String, dynamic>.from(message['d'] as Map);

    final isOwnPendingOp =
        message['from'] == clientId &&
        coreInfo.pendingOps.any((pending) => opInt(pending['cid']) == cid);
    if (isOwnPendingOp) {
      // The server received this operation but we never got its ack.
      // It's already applied locally.
      _removePending(cid);
      if (op['t'] == NoteOps.addStrokeType) {
        applier.addedStrokeIds.add((op['s'] as Map)['id'] as String);
      } else if (op['t'] == NoteOps.addImageType) {
        applier.addedImageIds.add((op['m'] as Map)['u'] as String);
      }
    } else {
      try {
        if (op['t'] == NoteOps.textDeltaType) {
          _onRemoteTextChange(op, seq);
        } else {
          applier.apply(
            op,
            pendingLocalOps: coreInfo.pendingOps.map(
              (pending) => Map<String, dynamic>.from(pending['d'] as Map),
            ),
            // An unsynced note's strokes are all sent once we've caught up
            isUnsent: (stroke) =>
                _needsSnapshot && !applier.addedStrokeIds.contains(stroke.id),
            // An unsynced note's text is sent once we've caught up too
            keepLocalText: _keepsLocalText,
          );
        }
      } catch (e, st) {
        log.severe('Failed to apply operation $seq: $e', e, st);
      }
      onRemoteChange();
    }

    _advanceSeq(seq);
    onLocalStateChange();
  }

  bool _keepsLocalText(EditorPage page) =>
      _needsSnapshot && !page.quill.controller.document.isEmpty();

  /// Applies a change that another device made to the text of a page.
  ///
  /// The server has numbered it before our own changes that it hasn't
  /// acknowledged yet, so it's transformed to apply after them here, and they
  /// are transformed to apply after it on the server, which does the same.
  void _onRemoteTextChange(NoteOp op, int seq) {
    final pageId = op['pg'] as String;
    final page = applier.pageForText(pageId);

    // Take note of what was just typed, which we may not have been told yet.
    textChanged(page);
    if (_keepsLocalText(page)) return;

    final pending = _pendingTextOps(coreInfo, pageId).toList();
    // Our whole text is on its way, and replaces whatever came before it.
    if (pending.any((p) => (p['d'] as Map)['t'] == NoteOps.textType)) return;

    var remote = Delta.fromJson(op['d'] as List);
    for (final envelope in pending) {
      final localOp = envelope['d'] as Map;
      final local = Delta.fromJson(localOp['d'] as List);
      localOp['d'] = remote.transform(local, true).toJson();
      localOp['b'] = seq;
      remote = local.transform(remote, false);
    }
    applier.applyTextChange(pageId, remote);
  }

  void _onSynced(int head) {
    final seq = coreInfo.realtimeSeq;
    if (seq != null && head < seq) {
      // The room doesn't have the history that this note was synced with,
      // e.g. the note was renamed or the server was reset.
      // Join it again as if this note had never been synced.
      log.info('Room $room is behind this note ($head < $seq), rejoining');
      coreInfo.realtimeSeq = null;
      coreInfo.pendingOps.clear();
      _socket?.close();
      return;
    }

    coreInfo.realtimeSeq = max(seq ?? 0, head);
    state.value = .live;
    _reconnectAttempts = 0;

    if (_needsSnapshot) {
      _needsSnapshot = false;
      coreInfo.pendingOps.clear();
      submit(
        NoteOps.snapshot(
          coreInfo,
          knownStrokeIds: applier.addedStrokeIds,
          knownImageIds: applier.addedImageIds,
          skipImages: applier.unsizedImages,
        ),
      );
    } else {
      coreInfo.pendingOps.toList().forEach(_sendIfReady);
    }
    onLocalStateChange();
  }

  /// Forgets the pending operation that the server has acknowledged.
  void _removePending(int cid) {
    final acknowledged = coreInfo.pendingOps
        .where((pending) => opInt(pending['cid']) == cid)
        .toList();
    for (final envelope in acknowledged) {
      coreInfo.pendingOps.remove(envelope);
      final op = envelope['d'] as Map;
      if (_isTextOp(op)) _sendNextTextOp(op['pg'] as String);
    }
  }

  void _advanceSeq(int seq) {
    if (seq > (coreInfo.realtimeSeq ?? 0)) coreInfo.realtimeSeq = seq;
  }

  /// Tells the other devices in the note where this user is,
  /// e.g. `{'pg': pageId, 'x': 10, 'y': 20}`, or that they've left it.
  void sendPresence(Map<String, dynamic>? presence) {
    if (state.value != .live) return;
    _send({'k': 'presence', 'd': presence});
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(BsonCodec.serialize(message).byteList);
  }

  /// Stops syncing for good, unlike when the connection is lost.
  void _stop(RealtimeStopReason reason) {
    if (_disposed || _stopReason != null) return;
    log.info('Stopped syncing $room: $reason');
    _stopReason = reason;
    _reconnectTimer?.cancel();
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    state.value = .offline;
    onStopped?.call(reason);
  }

  void _onDisconnected(WebSocket socket) {
    if (socket != _socket) return;
    _socket = null;
    if (_disposed) return;
    state.value = .offline;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _stopReason != null) return;
    final delay = minReconnectDelay * pow(2, min(_reconnectAttempts, 5));
    _reconnectAttempts++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      delay > maxReconnectDelay ? maxReconnectDelay : delay,
      _connect,
    );
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    final socket = _socket;
    _socket = null;
    unawaited(socket?.close());
    state.dispose();
  }
}
