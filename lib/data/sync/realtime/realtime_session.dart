import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bson/bson.dart';
import 'package:flutter/foundation.dart';
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
    this.hasUnsentText,
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

  final NoteOpApplier applier;
  EditorCoreInfo get coreInfo => applier.coreInfo;

  /// Called after an operation from another device has changed the note.
  final VoidCallback onRemoteChange;

  /// Called when [EditorCoreInfo.realtimeSeq] or
  /// [EditorCoreInfo.pendingOps] change, i.e. the note needs saving.
  final VoidCallback onLocalStateChange;

  /// Called when this session gives up on syncing the note.
  final void Function(RealtimeStopReason reason)? onStopped;

  /// Returns whether the text of a page has changes
  /// that haven't been passed to [submit] yet.
  final bool Function(EditorPage page)? hasUnsentText;

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
      if (state.value == .live) _send({'k': 'op', ...envelope});
    }
    onLocalStateChange();
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
        _removePending(opInt(message['cid']));
        _advanceSeq(opInt(message['seq']));
        onLocalStateChange();
      case 'synced':
        _onSynced(opInt(message['head']));
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
        applier.apply(
          op,
          pendingLocalOps: coreInfo.pendingOps.map(
            (pending) => Map<String, dynamic>.from(pending['d'] as Map),
          ),
          // An unsynced note's strokes are all sent once we've caught up
          isUnsent: (stroke) =>
              _needsSnapshot && !applier.addedStrokeIds.contains(stroke.id),
          // An unsynced note's text is sent once we've caught up too
          keepLocalText: (page) =>
              (_needsSnapshot && !page.quill.controller.document.isEmpty()) ||
              (hasUnsentText?.call(page) ?? false),
        );
      } catch (e, st) {
        log.severe('Failed to apply operation $seq: $e', e, st);
      }
      onRemoteChange();
    }

    _advanceSeq(seq);
    onLocalStateChange();
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
      for (final envelope in coreInfo.pendingOps) {
        _send({'k': 'op', ...envelope});
      }
    }
    onLocalStateChange();
  }

  void _removePending(int cid) {
    coreInfo.pendingOps.removeWhere((pending) => opInt(pending['cid']) == cid);
  }

  void _advanceSeq(int seq) {
    if (seq > (coreInfo.realtimeSeq ?? 0)) coreInfo.realtimeSeq = seq;
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
