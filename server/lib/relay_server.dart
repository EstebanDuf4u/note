import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:fixnum/fixnum.dart';
import 'package:noteplus_server/accounts.dart';
import 'package:noteplus_server/shares.dart';

int _int(dynamic value) => switch (value) {
  (final int value) => value,
  (final Int64 value) => value.toInt(),
  (final num value) => value.toInt(),
  _ => throw FormatException('Not an int: $value'),
};

/// Thrown when a device does something that it can't recover from by retrying.
class _Refusal implements Exception {
  const new(this.code, this.message);

  final String code, message;
}

/// Keeps the notes of each account in sync between the account's devices.
///
/// Devices sign in over HTTP (see [AccountStore]) and get a session token.
///
/// Each note is a "room" that belongs to one account. The server gives every
/// operation in a room a sequence number, appends it to the room's log on
/// disk, and forwards it to the account's other devices that have the note
/// open. A device that joins a room is first sent the operations it missed.
///
/// The server doesn't look inside an operation, except those that change
/// the text of a page: see [_Room._mergeText].
class RelayServer {
  new({
    required this.dataDirectory,
    this.allowRegistration = true,
    int passwordIterations = 100000,
    this.roomIdleTimeout = const Duration(minutes: 5),
  }) : accounts = AccountStore(
         File('${dataDirectory.path}/accounts.json'),
         passwordIterations: passwordIterations,
       ),
       shares = ShareStore(File('${dataDirectory.path}/shares.json'));

  /// Where the accounts and the room logs are stored.
  final Directory dataDirectory;

  /// Whether new accounts can be created.
  final bool allowRegistration;

  final AccountStore accounts;

  /// The links with which accounts open each other's notes.
  final ShareStore shares;

  /// How long a note stays in memory after its last device has left.
  final Duration roomIdleTimeout;

  /// The notes of each user that has connected since the server started.
  final _notes = <String, Future<_UserNotes>>{};
  HttpServer? _httpServer;

  static const _maxBodyLength = 64 * 1024;

  int get port => _httpServer!.port;

  Future<void> start({Object? address, int port = 8787}) async {
    await dataDirectory.create(recursive: true);
    await accounts.load();
    await shares.load();
    final httpServer = _httpServer = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
    );
    httpServer.listen(_onRequest);
  }

  Future<void> stop() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
    for (final notes in await Future.wait(_notes.values)) {
      await notes.close();
    }
    _notes.clear();
  }

  Future<_UserNotes> _notesOf(String userId) => _notes.putIfAbsent(
    userId,
    () => _UserNotes.open(
      Directory('${dataDirectory.path}/users/$userId'),
      roomIdleTimeout: roomIdleTimeout,
    ),
  );

  Future<void> _onRequest(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      return _onWebSocket(request);
    }

    try {
      final response = await _onHttpRequest(request);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(response));
    } on AccountException catch (e) {
      request.response
        ..statusCode = e.status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': e.code}));
    } catch (e) {
      stderr.writeln('${request.method} ${request.uri.path} failed: $e');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'server_error'}));
    }
    await request.response.close();
  }

  Future<Map<String, dynamic>> _onHttpRequest(HttpRequest request) async {
    switch ((request.method, request.uri.path)) {
      case ('GET', '/'):
        return {'server': 'noteplus', 'registration': allowRegistration};

      case ('POST', '/register'):
        if (!allowRegistration) {
          throw const AccountException(
            'registration_closed',
            HttpStatus.forbidden,
          );
        }
        final body = await _readBody(request);
        final (name, token) = await accounts.register(
          _string(body, 'username'),
          _string(body, 'password'),
        );
        return {'username': name, 'token': token};

      case ('POST', '/login'):
        final body = await _readBody(request);
        final (name, token) = await accounts.login(
          _string(body, 'username'),
          _string(body, 'password'),
        );
        return {'username': name, 'token': token};

      case ('POST', '/logout'):
        _authenticate(request);
        await accounts.logout(_bearerToken(request)!);
        return {};

      case ('GET', '/notes'):
        final userId = _authenticate(request);
        final notes = await _notesOf(userId);
        return {...await notes.list(), 'shared': await _sharedWith(userId)};

      case ('POST', '/notes/delete'):
        final userId = _authenticate(request);
        final notes = await _notesOf(userId);
        final body = await _readBody(request);
        final path = _string(body, 'path');
        await _unshare(userId, path);
        await notes.delete(path);
        return {};

      case ('POST', '/notes/share'):
        final userId = _authenticate(request);
        final body = await _readBody(request);
        return {'token': await shares.share(userId, _string(body, 'path'))};

      case ('POST', '/notes/unshare'):
        final userId = _authenticate(request);
        final body = await _readBody(request);
        await _unshare(userId, _string(body, 'path'));
        return {};

      case ('POST', '/notes/rename'):
        final userId = _authenticate(request);
        final body = await _readBody(request);
        await shares.renamed(
          userId,
          _string(body, 'from'),
          _string(body, 'to'),
        );
        return {};

      case ('POST', '/shares/accept'):
        final userId = _authenticate(request);
        final token = _string(await _readBody(request), 'token');
        final share = shares[token];
        if (share == null) {
          throw const AccountException('not_found', HttpStatus.notFound);
        }
        await shares.accept(userId, token);
        return {
          'token': token,
          'path': share.path,
          'owner': accounts.nameOf(share.owner),
          'own': share.owner == userId,
        };

      case ('POST', '/shares/leave'):
        final userId = _authenticate(request);
        await shares.leave(userId, _string(await _readBody(request), 'token'));
        return {};

      case ('GET', '/library'):
        final notes = await _notesOf(_authenticate(request));
        return {'entries': notes.library};

      case ('POST', '/library'):
        final notes = await _notesOf(_authenticate(request));
        final entries = (await _readBody(request))['entries'];
        if (entries is! Map<String, dynamic>) {
          throw const AccountException('bad_request', HttpStatus.badRequest);
        }
        return {'entries': await notes.mergeLibrary(entries)};

      default:
        throw const AccountException('not_found', HttpStatus.notFound);
    }
  }

  /// The notes of other accounts that [userId] opened from a link.
  Future<List<Map<String, dynamic>>> _sharedWith(String userId) async => [
    for (final token in shares.acceptedBy(userId))
      if (shares[token] case final share?)
        {
          'token': token,
          'path': share.path,
          'owner': accounts.nameOf(share.owner),
          'head': await (await _notesOf(share.owner)).headOf(share.path),
        },
  ];

  /// Stops sharing the note at [path] of [userId], and disconnects the
  /// other accounts that have it open.
  Future<void> _unshare(String userId, String path) async {
    final token = await shares.unshare(userId, path);
    if (token == null) return;
    final notes = await _notesOf(userId);
    notes.disconnectShare(path, token);
  }

  static String? _bearerToken(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring('Bearer '.length);
  }

  /// Returns the id of the user who sent [request].
  String _authenticate(HttpRequest request) {
    final userId = accounts.userIdFor(_bearerToken(request));
    if (userId == null) {
      throw const AccountException('unauthorized', HttpStatus.unauthorized);
    }
    return userId;
  }

  static Future<Map<String, dynamic>> _readBody(HttpRequest request) async {
    const badRequest = AccountException('bad_request', HttpStatus.badRequest);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > _maxBodyLength) throw badRequest;
    }
    try {
      return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
    } catch (_) {
      throw badRequest;
    }
  }

  static String _string(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty) {
      throw const AccountException('bad_request', HttpStatus.badRequest);
    }
    return value;
  }

  Future<void> _onWebSocket(HttpRequest request) async {
    // The socket is closed by the device, or by [_Room.close].
    // ignore: close_sinks
    final socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 20);
    final client = _Client(socket);

    // Messages are handled one at a time so that
    // operations keep the order they were sent in.
    var queue = Future<void>.value();
    socket.listen(
      (data) => queue = queue.then((_) => _onMessage(client, data)),
      onDone: () => client.room?.leave(client),
      onError: (Object _) => client.room?.leave(client),
      cancelOnError: true,
    );
  }

  Future<void> _onMessage(_Client client, dynamic data) async {
    try {
      if (data is! List<int>) throw const FormatException('Expected bson');
      final Map<String, dynamic> message = BsonCodec.deserialize(
        BsonBinary.from(data is Uint8List ? data : Uint8List.fromList(data)),
      );

      switch (message['k']) {
        case 'join':
          await _join(client, message);
        case 'presence':
          client.room?.relayPresence(client, message['d']);
        case 'op':
          final room = client.room;
          if (room == null) throw const FormatException('Join a room first');
          await room.append(
            client,
            cid: _int(message['cid']),
            op: message['d'],
          );
          await client.notes!.markAsWritten(room.path);
        default:
          throw FormatException('Unknown message kind: ${message['k']}');
      }
    } on _Refusal catch (e) {
      client.send({'k': 'error', 'code': e.code, 'message': e.message});
      await client.socket.close(WebSocketStatus.policyViolation);
    } catch (e) {
      client.send({'k': 'error', 'code': 'protocol', 'message': '$e'});
      await client.socket.close(WebSocketStatus.protocolError);
    }
  }

  Future<void> _join(_Client client, Map<String, dynamic> message) async {
    final userId = accounts.userIdFor(message['token'] as String?);
    if (userId == null) {
      throw const _Refusal('auth', 'Not signed in');
    }
    // A note of another account is opened with the token of its link.
    final shareToken = message['share'];
    final share = shareToken is String ? shares[shareToken] : null;
    if (shareToken is String && share == null) {
      client.send({'k': 'deleted'});
      return;
    }
    final path = share?.path ?? message['room'];
    final clientId = message['client'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('Missing room');
    }
    if (clientId is! String || clientId.isEmpty) {
      throw const FormatException('Missing client');
    }

    client.room?.leave(client);
    client.room = null;

    final notes = await _notesOf(share?.owner ?? userId);
    final room = await notes.join(
      path,
      create: share == null && message['create'] == true,
    );
    if (share != null) await shares.accept(userId, shareToken as String);
    if (room == null) {
      // The note was deleted on another device.
      client.send({'k': 'deleted'});
      return;
    }
    client
      ..id = clientId
      ..userName = accounts.nameOf(userId) ?? ''
      ..share = shareToken is String ? shareToken : null
      ..notes = notes
      ..room = room;

    // Operations can be appended while we read the older ones from disk,
    // so keep going until the device has them all, then start forwarding
    // new ones to it without letting another operation in between.
    room.cancelIdleClose();
    room.joining++;
    try {
      var sent = _int(message['since'] ?? 0).clamp(0, room.head);
      while (sent < room.head) {
        final end = room.head;
        await for (final frame in room.framesAfter(sent, end: end)) {
          if (client.room != room) return; // it joined another room meanwhile
          client.socket.add(frame);
        }
        sent = end;
      }
    } finally {
      room.joining--;
    }
    client.send({'k': 'synced', 'head': room.head});
    room.clients.add(client);
    room.cancelIdleClose();
  }
}

/// The notes of one account.
class _UserNotes {
  new _(this.directory, {required this.roomIdleTimeout});

  final Duration roomIdleTimeout;

  /// Where this account's room logs are stored.
  final Directory directory;

  /// The notes that have at least one operation.
  final _written = <String>{};

  /// The notes that were deleted, so that the account's other devices
  /// delete them too instead of sharing them again.
  final _deleted = <String>{};

  final _rooms = <String, Future<_Room>>{};

  /// How many operations each note that hasn't been opened yet has.
  final _closedHeads = <String, int>{};

  /// The last queued change to which notes exist.
  Future<void> _lastChange = Future.value();

  File get _indexFile => File('${directory.path}/notes.json');

  /// Whether each note is a favorite and which cover it has, by its path,
  /// along with when that last changed on the device that changed it.
  /// The app gives these meaning; the server keeps the latest of each.
  final library = <String, Map<String, dynamic>>{};

  File get _libraryFile => File('${directory.path}/library.json');

  /// Keeps those of [entries] that are newer than what we have,
  /// and returns the whole library.
  Future<Map<String, Map<String, dynamic>>> mergeLibrary(
    Map<String, dynamic> entries,
  ) => _synchronized(() async {
    var changed = false;
    for (final MapEntry(key: path, value: entry) in entries.entries) {
      if (entry is! Map<String, dynamic>) continue;
      final time = entry['t'];
      if (time is! num) continue;
      final current = library[path]?['t'] as num?;
      if (current != null && current >= time) continue;
      library[path] = entry;
      changed = true;
    }
    if (changed) {
      final temporary = File('${_libraryFile.path}.tmp');
      await temporary.writeAsString(jsonEncode(library), flush: true);
      await temporary.rename(_libraryFile.path);
    }
    return library;
  });

  static Future<_UserNotes> open(
    Directory directory, {
    required Duration roomIdleTimeout,
  }) async {
    await directory.create(recursive: true);
    final notes = _UserNotes._(directory, roomIdleTimeout: roomIdleTimeout);
    if (notes._indexFile.existsSync()) {
      final json = jsonDecode(
        await notes._indexFile.readAsString(),
      ) as Map<String, dynamic>;
      notes._written.addAll((json['notes'] as List).cast());
      notes._deleted.addAll((json['deleted'] as List).cast());
    }
    if (notes._libraryFile.existsSync()) {
      final json = jsonDecode(await notes._libraryFile.readAsString()) as Map;
      for (final MapEntry(:key, :value) in json.entries) {
        notes.library[key as String] = Map<String, dynamic>.from(value as Map);
      }
    }
    return notes;
  }

  /// Runs [change] after the changes that were queued before it.
  Future<T> _synchronized<T>(Future<T> Function() change) {
    final result = _lastChange.then((_) => change());
    _lastChange = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _saveIndex() async {
    final temporary = File('${_indexFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'notes': _written.toList(), 'deleted': _deleted.toList()}),
      flush: true,
    );
    await temporary.rename(_indexFile.path);
  }

  File _logFileFor(String path) {
    final name = sha256.convert(utf8.encode(path)).toString();
    return File('${directory.path}/$name.log');
  }

  /// Returns the room of the note at [path], or null if the note was deleted.
  ///
  /// [create] is whether the device is sharing a note that it has never
  /// synced, which replaces a deleted note of the same name.
  Future<_Room?> join(String path, {required bool create}) =>
      _synchronized(() async {
        if (_deleted.contains(path)) {
          if (!create) return null;
          _deleted.remove(path);
          await _saveIndex();
        }
        return _rooms.putIfAbsent(path, () async {
          final room = await _Room.open(path, _logFileFor(path));
          room
            ..idleTimeout = roomIdleTimeout
            ..onIdle = () => _unload(path, room);
          return room;
        });
      });

  /// Frees the memory of a room that no device has open.
  Future<void> _unload(String path, _Room room) => _synchronized(() async {
    if (!room.isIdle) return;
    final loaded = _rooms[path];
    if (loaded == null || await loaded != room) return;
    _rooms.remove(path);
    _closedHeads[path] = room.head;
    await room.close();
  });

  /// Records that the note at [path] has operations.
  Future<void> markAsWritten(String path) async {
    if (_written.contains(path)) return;
    await _synchronized(() async {
      if (_deleted.contains(path) || !_written.add(path)) return;
      await _saveIndex();
    });
  }

  /// Deletes the note at [path] and its history.
  Future<void> delete(String path) => _synchronized(() async {
    final room = await _rooms.remove(path);
    if (room != null) {
      for (final client in room.clients) {
        client
          ..send({'k': 'deleted'})
          ..room = null;
      }
      await room.close();
    }
    final log = _logFileFor(path);
    if (log.existsSync()) await log.delete();
    _closedHeads.remove(path);

    _written.remove(path);
    _deleted.add(path);
    await _saveIndex();
  });

  /// Returns how many operations the note at [path] has.
  Future<int> headOf(String path) async =>
      (await _rooms[path])?.head ??
      (_closedHeads[path] ??= await _Room.countOperations(_logFileFor(path)));

  /// Disconnects the devices that opened the note at [path] with the link
  /// [token], which no longer gives access to it.
  void disconnectShare(String path, String token) {
    final room = _rooms[path];
    if (room == null) return;
    room.then((room) {
      for (final client in room.clients.toList()) {
        if (client.share != token) continue;
        client.send({'k': 'deleted'});
        room.leave(client);
        client.room = null;
      }
    });
  }

  /// Returns the notes of this account for `GET /notes`.
  Future<Map<String, dynamic>> list() => _synchronized(() async {
    final notes = <Map<String, dynamic>>[];
    for (final path in _written) {
      final room = await _rooms[path];
      final head =
          room?.head ??
          (_closedHeads[path] ??= await _Room.countOperations(
            _logFileFor(path),
          ));
      notes.add({'path': path, 'head': head});
    }
    return {'notes': notes, 'deleted': _deleted.toList()};
  });

  Future<void> close() => _synchronized(() async {
    for (final room in await Future.wait(_rooms.values)) {
      await room.close();
    }
    _rooms.clear();
  });
}

class _Client {
  new(this.socket);

  final WebSocket socket;
  var id = '';

  /// The name of the account that this device is signed in to.
  var userName = '';

  /// The token of the link that this device opened the note with,
  /// if it's another account's note.
  String? share;
  _UserNotes? notes;
  _Room? room;

  void send(Map<String, dynamic> message) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(BsonCodec.serialize(message).byteList);
  }
}

class _Room {
  new _(this.path, this._log);

  /// The path of the note in the user's library.
  final String path;

  /// Where each operation of this room is in its log file, in order.
  /// The operation at index `i` has the sequence number `i + 1`.
  ///
  /// The operations themselves stay on disk, since they include the images
  /// of the note, and are read when a device needs to catch up.
  final _offsets = <({int start, int length})>[];

  /// The operations that were appended recently, by sequence number,
  /// which devices that were briefly offline are likely to ask for.
  final _recentFrames = <int, Uint8List>{};
  static const _maxRecentFrames = 256;
  var _recentBytes = 0;
  static const _maxRecentBytes = 4 * 1024 * 1024;

  /// Where the next operation goes in the log file.
  var _logLength = 0;

  /// The id of the last operation received from each device,
  /// used to ignore operations that a device sends twice.
  final _lastOpIds = <String, int>{};

  final RandomAccessFile _log;
  final clients = <_Client>{};

  /// How long a room stays loaded after its last device has left.
  var idleTimeout = const Duration(minutes: 5);
  Timer? _idleTimer;

  /// Called when no device has had this room open for [idleTimeout].
  void Function()? onIdle;

  /// Tells the other devices in the room where [sender]'s user is
  /// in the note, or that they've left if [presence] is null.
  /// This isn't kept in the log: it only matters to those here now.
  void relayPresence(_Client sender, dynamic presence) {
    if (presence != null && presence is! Map) return;
    final message = BsonCodec.serialize({
      'k': 'presence',
      'from': sender.id,
      'user': sender.userName,
      'd': presence,
    }).byteList;
    for (final client in clients) {
      if (client == sender) continue;
      if (client.socket.readyState != WebSocket.open) continue;
      client.socket.add(message);
    }
  }

  /// How many devices are catching up before joining [clients].
  var joining = 0;

  bool get isIdle => clients.isEmpty && joining == 0;

  void leave(_Client client) {
    if (!clients.remove(client)) return;
    relayPresence(client, null);
    if (clients.isNotEmpty) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => onIdle?.call());
  }

  void cancelIdleClose() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  int get head => _offsets.length;

  /// Returns how many operations are in the log [file], without loading them.
  static Future<int> countOperations(File file) async {
    if (!file.existsSync()) return 0;
    final log = await file.open();
    try {
      final length = await log.length();
      var offset = 0, count = 0;
      while (offset + 4 <= length) {
        await log.setPosition(offset);
        final header = await log.read(4);
        final frameLength = ByteData.sublistView(header).getUint32(0);
        if (offset + 4 + frameLength > length) break; // partial write
        offset += 4 + frameLength;
        count++;
      }
      return count;
    } finally {
      await log.close();
    }
  }

  static Future<_Room> open(String path, File file) async {
    if (!file.existsSync()) await file.create(recursive: true);
    final room = _Room._(path, await file.open(mode: FileMode.append));

    // Each entry is a 4 byte length followed by the frame.
    // The log is read one entry at a time so that a note
    // with large images doesn't have to fit in memory.
    final reader = await file.open();
    try {
      final length = await reader.length();
      var offset = 0;
      while (offset + 4 <= length) {
        await reader.setPosition(offset);
        final header = await reader.read(4);
        final frameLength = ByteData.sublistView(header).getUint32(0);
        if (offset + 4 + frameLength > length) break; // partial write
        room._offsets.add((start: offset + 4, length: frameLength));

        final Map<String, dynamic> message = BsonCodec.deserialize(
          BsonBinary.from(await reader.read(frameLength)),
        );
        room._lastOpIds[message['from'] as String] = _int(message['cid']);
        room._recordText(
          message['d'],
          seq: room._offsets.length,
          from: message['from'] as String,
        );
        offset += 4 + frameLength;
      }
      room._logLength = offset;
      if (offset != length) await room._log.truncate(offset);
    } finally {
      await reader.close();
    }

    return room;
  }

  /// Returns the operations that follow the one numbered [seq].
  ///
  /// Stops at the operations that were appended while it was reading.
  Stream<Uint8List> framesAfter(int seq, {required int end}) async* {
    seq = seq.clamp(0, end);
    RandomAccessFile? reader;
    try {
      for (var i = seq; i < end; ++i) {
        if (_recentFrames[i + 1] case final frame?) {
          yield frame;
          continue;
        }
        reader ??= await _logFile.open();
        final (:start, :length) = _offsets[i];
        await reader.setPosition(start);
        yield await reader.read(length);
      }
    } finally {
      await reader?.close();
    }
  }

  File get _logFile => File(_log.path);

  /// The last queued [append], so that operations from
  /// different devices are numbered one at a time.
  Future<void> _lastAppend = Future.value();

  Future<void> append(_Client sender, {required int cid, required dynamic op}) {
    final result = _lastAppend.then((_) => _append(sender, cid: cid, op: op));
    _lastAppend = result.catchError((Object _) {});
    return result;
  }

  Future<void> _append(
    _Client sender, {
    required int cid,
    required dynamic op,
  }) async {
    if (op is! Map) throw const FormatException('Missing operation');

    final lastOpId = _lastOpIds[sender.id];
    if (lastOpId != null && cid <= lastOpId) {
      // We already have this operation, the device just didn't get our ack.
      sender.send({'k': 'ack', 'cid': cid, 'seq': head});
      return;
    }

    final seq = head + 1;
    op = _mergeText(op, seq: seq, from: sender.id);
    final frame = BsonCodec.serialize({
      'k': 'op',
      'seq': seq,
      'from': sender.id,
      'cid': cid,
      'd': op,
    }).byteList;

    final entry = BytesBuilder(copy: false)
      ..add((ByteData(4)..setUint32(0, frame.length)).buffer.asUint8List())
      ..add(frame);
    await _log.writeFrom(entry.takeBytes());
    await _log.flush();

    _offsets.add((start: _logLength + 4, length: frame.length));
    _logLength += 4 + frame.length;
    _remember(seq, frame);
    _lastOpIds[sender.id] = cid;

    sender.send({'k': 'ack', 'cid': cid, 'seq': seq});
    for (final client in clients) {
      if (client == sender) continue;
      if (client.socket.readyState != WebSocket.open) continue;
      client.socket.add(frame);
    }
  }

  void _remember(int seq, Uint8List frame) {
    _recentFrames[seq] = frame;
    _recentBytes += frame.length;
    while (_recentFrames.length > _maxRecentFrames ||
        _recentBytes > _maxRecentBytes) {
      final oldest = _recentFrames.keys.first;
      _recentBytes -= _recentFrames.remove(oldest)!.length;
    }
  }

  /// The text of each page that has some, by the page's id.
  final _texts = <String, _PageText>{};

  static const _textDeltaType = 'qd', _textType = 'qt';

  /// Rewrites an operation that changes the text of a page so that it applies
  /// to the text as it is now, and returns it. Other operations are returned
  /// as they are.
  ///
  /// A device describes its change (`qd`) relative to the text it had, which
  /// was up to date with the operation numbered `b`. If other devices changed
  /// the same text since then, the change is transformed so that both changes
  /// are kept, e.g. two people typing in different places of a paragraph.
  ///
  /// A device can also send a whole text (`qt`), when it shares a note for
  /// the first time. It's rewritten as the change that leads to that text.
  Map<dynamic, dynamic> _mergeText(
    Map<dynamic, dynamic> op, {
    required int seq,
    required String from,
  }) {
    final type = op['t'], pageId = op['pg'];
    if ((type != _textDeltaType && type != _textType) || pageId is! String) {
      return op;
    }

    final text = _texts.putIfAbsent(pageId, _PageText.new);
    try {
      Delta change;
      if (type == _textType) {
        change = text.document.diff(Delta.fromJson(op['q'] as List));
      } else {
        change = Delta.fromJson(op['d'] as List);
        final base = _int(op['b'] ?? seq - 1);
        for (final other in text.changes) {
          // a device sends its changes to a text one at a time, so its
          // own earlier changes are already part of what it describes
          if (other.seq <= base || other.from == from) continue;
          change = other.delta.transform(change, true);
        }
      }
      text.document = text.document.compose(change);
      text.addChange(seq: seq, from: from, delta: change);
      return {'t': _textDeltaType, 'pg': pageId, 'd': change.toJson()};
    } catch (e) {
      stderr.writeln('Dropped a change to the text of page $pageId: $e');
      return {'t': _textDeltaType, 'pg': pageId, 'd': const <dynamic>[]};
    }
  }

  /// Takes note of a text change that is already in the log.
  void _recordText(dynamic op, {required int seq, required String from}) {
    if (op is! Map || op['t'] != _textDeltaType) return;
    final pageId = op['pg'];
    if (pageId is! String) return;
    try {
      final change = Delta.fromJson(op['d'] as List);
      final text = _texts.putIfAbsent(pageId, _PageText.new);
      text.document = text.document.compose(change);
      text.addChange(seq: seq, from: from, delta: change);
    } catch (e) {
      stderr.writeln('Invalid text change in the log of $path: $e');
    }
  }

  Future<void> close() async {
    cancelIdleClose();
    // Don't wait for the devices to confirm, since one that has
    // stopped responding would keep the server from stopping.
    for (final client in clients.toList()) {
      unawaited(client.socket.close(WebSocketStatus.goingAway));
    }
    clients.clear();
    await _lastAppend;
    await _log.close();
  }
}

/// The text of a page, and the changes that led to it.
class _PageText {
  /// A page's text is a paragraph break until something is typed.
  var document = Delta()..insert('\n');

  final changes = <({int seq, String from, Delta delta})>[];

  /// How many recent changes are kept to merge late changes with.
  /// A device that was offline for longer than that has its change applied
  /// on top of the text as it is, which can put it slightly off place.
  static const _maxChanges = 500;

  void addChange({
    required int seq,
    required String from,
    required Delta delta,
  }) {
    changes.add((seq: seq, from: from, delta: delta));
    if (changes.length > _maxChanges) {
      changes.removeRange(0, changes.length - _maxChanges);
    }
  }
}
