import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:fixnum/fixnum.dart';
import 'package:noteplus_server/accounts.dart';

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
  }) : accounts = AccountStore(
         File('${dataDirectory.path}/accounts.json'),
         passwordIterations: passwordIterations,
       );

  /// Where the accounts and the room logs are stored.
  final Directory dataDirectory;

  /// Whether new accounts can be created.
  final bool allowRegistration;

  final AccountStore accounts;

  /// The notes of each user that has connected since the server started.
  final _notes = <String, Future<_UserNotes>>{};
  HttpServer? _httpServer;

  static const _maxBodyLength = 64 * 1024;

  int get port => _httpServer!.port;

  Future<void> start({Object? address, int port = 8787}) async {
    await dataDirectory.create(recursive: true);
    await accounts.load();
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
    () => _UserNotes.open(Directory('${dataDirectory.path}/users/$userId')),
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
        final notes = await _notesOf(_authenticate(request));
        return notes.list();

      case ('POST', '/notes/delete'):
        final notes = await _notesOf(_authenticate(request));
        final body = await _readBody(request);
        await notes.delete(_string(body, 'path'));
        return {};

      default:
        throw const AccountException('not_found', HttpStatus.notFound);
    }
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
      onDone: () => client.room?.clients.remove(client),
      onError: (Object _) => client.room?.clients.remove(client),
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
    final path = message['room'];
    final clientId = message['client'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('Missing room');
    }
    if (clientId is! String || clientId.isEmpty) {
      throw const FormatException('Missing client');
    }

    client.room?.clients.remove(client);
    client.room = null;

    final notes = await _notesOf(userId);
    final room = await notes.join(path, create: message['create'] == true);
    if (room == null) {
      // The note was deleted on another device.
      client.send({'k': 'deleted'});
      return;
    }
    client
      ..id = clientId
      ..notes = notes
      ..room = room;

    for (final frame in room.framesAfter(_int(message['since'] ?? 0))) {
      client.socket.add(frame);
    }
    client.send({'k': 'synced', 'head': room.head});
    room.clients.add(client);
  }
}

/// The notes of one account.
class _UserNotes {
  new _(this.directory);

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

  static Future<_UserNotes> open(Directory directory) async {
    await directory.create(recursive: true);
    final notes = _UserNotes._(directory);
    if (notes._indexFile.existsSync()) {
      final json = jsonDecode(
        await notes._indexFile.readAsString(),
      ) as Map<String, dynamic>;
      notes._written.addAll((json['notes'] as List).cast());
      notes._deleted.addAll((json['deleted'] as List).cast());
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
        return _rooms.putIfAbsent(
          path,
          () => _Room.open(path, _logFileFor(path)),
        );
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

  /// The operations of this room in order, each as it's sent to devices.
  /// The operation at index `i` has the sequence number `i + 1`.
  final _frames = <Uint8List>[];

  /// The id of the last operation received from each device,
  /// used to ignore operations that a device sends twice.
  final _lastOpIds = <String, int>{};

  final RandomAccessFile _log;
  final clients = <_Client>{};

  int get head => _frames.length;

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
    final room = _Room._(path, await file.open(mode: FileMode.append));

    // Each entry is a 4 byte length followed by the frame.
    final bytes = await file.readAsBytes();
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 4 <= bytes.length) {
      final length = view.getUint32(offset);
      if (offset + 4 + length > bytes.length) break; // partial write
      final frame = Uint8List.sublistView(
        bytes,
        offset + 4,
        offset + 4 + length,
      );
      final Map<String, dynamic> message = BsonCodec.deserialize(
        BsonBinary.from(frame),
      );
      room._frames.add(frame);
      room._lastOpIds[message['from'] as String] = _int(message['cid']);
      room._recordText(
        message['d'],
        seq: room._frames.length,
        from: message['from'] as String,
      );
      offset += 4 + length;
    }
    if (offset != bytes.length) await room._log.truncate(offset);

    return room;
  }

  Iterable<Uint8List> framesAfter(int seq) => _frames.skip(seq.clamp(0, head));

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

    _frames.add(frame);
    _lastOpIds[sender.id] = cid;

    sender.send({'k': 'ack', 'cid': cid, 'seq': seq});
    for (final client in clients) {
      if (client == sender) continue;
      if (client.socket.readyState != WebSocket.open) continue;
      client.socket.add(frame);
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
      text.changes.add((seq: seq, from: from, delta: change));
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
      text.changes.add((seq: seq, from: from, delta: change));
    } catch (e) {
      stderr.writeln('Invalid text change in the log of $path: $e');
    }
  }

  Future<void> close() async {
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
}
