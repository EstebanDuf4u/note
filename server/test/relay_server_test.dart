import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:fixnum/fixnum.dart';
import 'package:noteplus_server/accounts.dart';
import 'package:noteplus_server/relay_server.dart';
import 'package:test/test.dart';

int _int(dynamic value) => value is Int64 ? value.toInt() : value as int;

class _TestClient {
  new(this.socket, this.token) {
    socket.listen((data) {
      messages.add(BsonCodec.deserialize(BsonBinary.from(data as Uint8List)));
      _changed.add(null);
    });
  }

  static Future<_TestClient> connect(RelayServer server, String token) async =>
      _TestClient(
        await WebSocket.connect('ws://127.0.0.1:${server.port}'),
        token,
      );

  final WebSocket socket;
  final String token;
  final messages = <Map<String, dynamic>>[];
  final _changed = StreamController<void>.broadcast();

  void send(Map<String, dynamic> message) =>
      socket.add(BsonCodec.serialize(message).byteList);

  void join(
    String room,
    String client, {
    int since = 0,
    bool create = false,
    String? share,
  }) => send({
    'k': 'join',
    'room': room,
    'client': client,
    'since': since,
    'token': token,
    'create': create,
    'share': ?share,
  });

  /// Waits until [count] messages of [kind] have been received.
  Future<List<Map<String, dynamic>>> waitFor(String kind, int count) async {
    List<Map<String, dynamic>> matching() =>
        messages.where((message) => message['k'] == kind).toList();
    while (matching().length < count) {
      await _changed.stream.first.timeout(const Duration(seconds: 5));
    }
    return matching();
  }
}

void main() {
  late Directory dataDirectory;
  late RelayServer server;
  late String token;
  final http = HttpClient();

  Future<void> startServer({bool allowRegistration = true}) async {
    server = RelayServer(
      dataDirectory: dataDirectory,
      allowRegistration: allowRegistration,
      passwordIterations: 100,
      roomIdleTimeout: const Duration(milliseconds: 50),
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  }

  /// Returns the status and the body of the response.
  Future<(int, Map<String, dynamic>)> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    final request = await http.open(method, '127.0.0.1', server.port, path);
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
  }

  Future<String> register(
    String username, [
    String password = 'password',
  ]) async {
    final (status, body) = await request(
      'POST',
      '/register',
      body: {'username': username, 'password': password},
    );
    expect(status, 200, reason: '$body');
    return body['token'] as String;
  }

  setUp(() async {
    dataDirectory = await Directory.systemTemp.createTemp('noteplus_server');
    await startServer();
    token = await register('alice');
  });
  tearDown(() async {
    await server.stop();
    await dataDirectory.delete(recursive: true);
  });

  group('Accounts', () {
    test('pbkdf2 matches a known value', () {
      // from RFC 7914, section 11
      final hash = pbkdf2(utf8.encode('passwd'), utf8.encode('salt'), 1);
      expect(
        hash.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc',
      );
    });

    test('signing in with the right password', () async {
      final (status, body) = await request(
        'POST',
        '/login',
        body: {'username': 'Alice', 'password': 'password'},
      );
      expect(status, 200);
      expect(body['username'], 'alice');
      expect(body['token'], isNot(token));

      final (notesStatus, _) = await request(
        'GET',
        '/notes',
        token: body['token'] as String,
      );
      expect(notesStatus, 200);
    });

    test('the wrong password or an unknown user is refused', () async {
      for (final username in ['alice', 'nobody']) {
        final (status, body) = await request(
          'POST',
          '/login',
          body: {'username': username, 'password': 'not the password'},
        );
        expect(status, 401);
        expect(body['error'], 'wrong_credentials');
      }
    });

    test('too many wrong passwords lock the account for a while', () async {
      for (int i = 0; i < AccountStore.maxFailedLogins; ++i) {
        await request(
          'POST',
          '/login',
          body: {'username': 'alice', 'password': 'guess $i'},
        );
      }
      final (status, body) = await request(
        'POST',
        '/login',
        body: {'username': 'alice', 'password': 'password'},
      );
      expect(status, 429);
      expect(body['error'], 'too_many_attempts');
    });

    test('usernames are unique and passwords have a minimum length', () async {
      Future<String?> errorOf(String username, String password) async =>
          (await request(
                'POST',
                '/register',
                body: {'username': username, 'password': password},
              )).$2['error']
              as String?;

      expect(await errorOf('ALICE', 'password'), 'username_taken');
      expect(await errorOf('bob', 'short'), 'weak_password');
      expect(await errorOf('b', 'password'), 'invalid_username');
      expect(await errorOf('bob/../alice', 'password'), 'invalid_username');
      expect(await errorOf('bob', 'password'), isNull);
    });

    test('registration can be closed', () async {
      await server.stop();
      await startServer(allowRegistration: false);
      final (status, body) = await request(
        'POST',
        '/register',
        body: {'username': 'bob', 'password': 'password'},
      );
      expect(status, 403);
      expect(body['error'], 'registration_closed');

      // but existing accounts still work
      final (loginStatus, _) = await request(
        'POST',
        '/login',
        body: {'username': 'alice', 'password': 'password'},
      );
      expect(loginStatus, 200);
    });

    test('accounts and sessions survive a restart', () async {
      await server.stop();
      await startServer();
      expect((await request('GET', '/notes', token: token)).$1, 200);
    });

    test('signing out ends the session', () async {
      expect((await request('POST', '/logout', token: token)).$1, 200);
      expect((await request('GET', '/notes', token: token)).$1, 401);

      final client = await _TestClient.connect(server, token)
        ..join('/n', 'a');
      final errors = await client.waitFor('error', 1);
      expect(errors.single['code'], 'auth');
    });

    test('passwords are not stored', () async {
      final stored = await File('${dataDirectory.path}/accounts.json')
          .readAsString();
      expect(stored, isNot(contains('password')));
      expect(stored, isNot(contains(token)));
    });
  });

  group('Notes', () {
    test('relays operations to the other devices in the room', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      final other = await _TestClient.connect(server, token)
        ..join('/other', 'c');
      await Future.wait([
        a.waitFor('synced', 1),
        b.waitFor('synced', 1),
        other.waitFor('synced', 1),
      ]);

      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'t': 'x', 'n': 1},
      });
      a.send({
        'k': 'op',
        'cid': 2,
        'd': {'t': 'x', 'n': 2},
      });

      final acks = await a.waitFor('ack', 2);
      expect(acks.map((ack) => _int(ack['seq'])), [1, 2]);

      final ops = await b.waitFor('op', 2);
      expect(ops.map((op) => _int(op['seq'])), [1, 2]);
      expect(ops.map((op) => op['from']), ['a', 'a']);
      expect(ops.map((op) => (op['d'] as Map)['n']), [1, 2]);

      // the sender doesn't get its own operations back
      expect(a.messages.where((message) => message['k'] == 'op'), isEmpty);
      expect(other.messages.where((message) => message['k'] == 'op'), isEmpty);
    });

    test('merges changes made to the same text at the same time', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      await Future.wait([a.waitFor('synced', 1), b.waitFor('synced', 1)]);

      // a shares the whole text, which becomes a change to an empty text
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {
          't': 'qt',
          'pg': 'p0',
          'q': [
            {'insert': 'Hello world\n'},
          ],
        },
      });
      final first = (await b.waitFor('op', 1)).single;
      expect(first['d'], {
        't': 'qd',
        'pg': 'p0',
        'd': [
          {'insert': 'Hello world'},
        ],
      });

      // both devices change the text that they've seen up to operation 1
      a.send({
        'k': 'op',
        'cid': 2,
        'd': {
          't': 'qd',
          'pg': 'p0',
          'b': 1,
          'd': [
            {'insert': 'Oh, '},
          ],
        },
      });
      // b's change is sent before it has seen a's, but arrives after it
      await a.waitFor('ack', 2);
      b.send({
        'k': 'op',
        'cid': 1,
        'd': {
          't': 'qd',
          'pg': 'p0',
          'b': 1,
          'd': [
            {'retain': 5},
            {'insert': ' there'},
          ],
        },
      });

      // b's change is moved to where "Hello" ends now
      final toA = (await a.waitFor('op', 1)).single;
      expect(_int(toA['seq']), 3);
      expect((toA['d'] as Map)['d'], [
        {'retain': 9},
        {'insert': ' there'},
      ]);

      // a device that joins later gets the merged changes
      await server.stop();
      await startServer();
      final c = await _TestClient.connect(server, token)
        ..join('/note', 'c');
      final ops = await c.waitFor('op', 3);
      expect(ops.map((op) => (op['d'] as Map)['d']), [
        [
          {'insert': 'Hello world'},
        ],
        [
          {'insert': 'Oh, '},
        ],
        [
          {'retain': 9},
          {'insert': ' there'},
        ],
      ]);

      // and a change based on everything isn't transformed
      c.send({
        'k': 'op',
        'cid': 1,
        'd': {
          't': 'qd',
          'pg': 'p0',
          'b': 3,
          'd': [
            {'delete': 4},
          ],
        },
      });
      await c.waitFor('ack', 1);
      final d = await _TestClient.connect(server, token)
        ..join('/note', 'd');
      final last = (await d.waitFor('op', 4)).last;
      expect((last['d'] as Map)['d'], [
        {'delete': 4},
      ]);
    });

    test('sends the missed operations when joining', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      await a.waitFor('synced', 1);
      for (int i = 1; i <= 3; ++i) {
        a.send({
          'k': 'op',
          'cid': i,
          'd': {'n': i},
        });
      }
      await a.waitFor('ack', 3);

      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b', since: 1);
      final synced = await b.waitFor('synced', 1);
      expect(_int(synced.single['head']), 3);
      expect(b.messages.map((message) => message['k']), ['op', 'op', 'synced']);
      expect(b.messages.take(2).map((message) => _int(message['seq'])), [2, 3]);
    });

    test('a note that nobody has open is reloaded from disk', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      await a.waitFor('synced', 1);
      // large enough to be read in several pieces
      final big = Uint8List(300 * 1024)..fillRange(0, 300 * 1024, 7);
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1, 'b': BsonBinary.from(big)},
      });
      a.send({
        'k': 'op',
        'cid': 2,
        'd': {'n': 2},
      });
      await a.waitFor('ack', 2);
      await a.socket.close();

      // the room is unloaded once it has been idle for a while
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final (_, list) = await request('GET', '/notes', token: token);
      expect(_int((list['notes'] as List).single['head']), 2);

      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      await b.waitFor('synced', 1);
      final ops = b.messages.where((m) => m['k'] == 'op').toList();
      expect(ops.map((op) => (op['d'] as Map)['n']), [1, 2]);
      expect(((ops.first['d'] as Map)['b'] as BsonBinary).byteList, big);

      // and new operations are numbered after the old ones
      b.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 3},
      });
      final acks = await b.waitFor('ack', 1);
      expect(_int(acks.single['seq']), 3);
    });

    test('ignores operations that are sent twice', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      await Future.wait([a.waitFor('synced', 1), b.waitFor('synced', 1)]);

      a.send({
        'k': 'op',
        'cid': 5,
        'd': {'n': 1},
      });
      a.send({
        'k': 'op',
        'cid': 5,
        'd': {'n': 1},
      });
      a.send({
        'k': 'op',
        'cid': 6,
        'd': {'n': 2},
      });
      await a.waitFor('ack', 3);

      final ops = await b.waitFor('op', 2);
      expect(ops.map((op) => (op['d'] as Map)['n']), [1, 2]);
      expect(ops.map((op) => _int(op['seq'])), [1, 2]);
    });

    test('keeps the operations after a restart', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      await a.waitFor('synced', 1);
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      await a.waitFor('ack', 1);

      await server.stop();
      await startServer();

      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      final ops = await b.waitFor('op', 1);
      expect((ops.single['d'] as Map)['n'], 1);

      // and it still knows which operations it has seen
      final a2 = await _TestClient.connect(server, token)
        ..join('/note', 'a', since: 1);
      await a2.waitFor('synced', 1);
      a2.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      await a2.waitFor('ack', 1);
      a2.send({
        'k': 'op',
        'cid': 2,
        'd': {'n': 2},
      });
      final acks = await a2.waitFor('ack', 2);
      expect(_int(acks.last['seq']), 2);
    });

    test('requires a session', () async {
      final wrong = await _TestClient.connect(server, 'not a token')
        ..join('/note', 'a');
      final errors = await wrong.waitFor('error', 1);
      expect(errors.single['code'], 'auth');
      expect((await request('GET', '/notes')).$1, 401);
    });

    test('each account has its own notes', () async {
      final bobToken = await register('bob');
      final alice = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      final bob = await _TestClient.connect(server, bobToken)
        ..join('/note', 'b');
      await Future.wait([alice.waitFor('synced', 1), bob.waitFor('synced', 1)]);

      alice.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      await alice.waitFor('ack', 1);

      // bob's note of the same name is a different note
      bob.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 2},
      });
      final acks = await bob.waitFor('ack', 1);
      expect(_int(acks.single['seq']), 1);
      expect(bob.messages.where((message) => message['k'] == 'op'), isEmpty);
      expect(alice.messages.where((message) => message['k'] == 'op'), isEmpty);

      final (_, bobNotes) = await request('GET', '/notes', token: bobToken);
      expect(bobNotes['notes'], [
        {'path': '/note', 'head': 1},
      ]);
    });

    test('lists the notes that have been written to', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/empty', 'a');
      await a.waitFor('synced', 1);
      a.join('/folder/note', 'a');
      await a.waitFor('synced', 2);
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      a.send({
        'k': 'op',
        'cid': 2,
        'd': {'n': 2},
      });
      await a.waitFor('ack', 2);

      Future<Map<String, dynamic>> list() async =>
          (await request('GET', '/notes', token: token)).$2;
      expect(await list(), {
        'notes': [
          {'path': '/folder/note', 'head': 2},
        ],
        'deleted': <String>[],
        'shared': <dynamic>[],
      });

      // also when the note hasn't been opened since the server started
      await server.stop();
      await startServer();
      expect((await list())['notes'], [
        {'path': '/folder/note', 'head': 2},
      ]);
    });

    test('a note is shared with another account through its link', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/Maths', 'a');
      await a.waitFor('synced', 1);
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      await a.waitFor('ack', 1);

      var (status, body) = await request(
        'POST',
        '/notes/share',
        token: token,
        body: {'path': '/Maths'},
      );
      expect(status, 200);
      final link = body['token'] as String;
      // sharing again gives the same link
      (_, body) = await request(
        'POST',
        '/notes/share',
        token: token,
        body: {'path': '/Maths'},
      );
      expect(body['token'], link);

      final bobToken = await register('bob');
      (status, body) = await request(
        'POST',
        '/shares/accept',
        token: bobToken,
        body: {'token': link},
      );
      expect(body['owner'], 'alice');
      expect(body['path'], '/Maths');

      // bob sees alice's operations and his reach alice
      final b = await _TestClient.connect(server, bobToken)
        ..join('ignored', 'b', share: link);
      final ops = await b.waitFor('op', 1);
      expect((ops.single['d'] as Map)['n'], 1);
      await b.waitFor('synced', 1);
      b.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 2},
      });
      final aOps = await a.waitFor('op', 1);
      expect((aOps.single['d'] as Map)['n'], 2);

      // where each one is in the note, which isn't kept
      b.send({
        'k': 'presence',
        'd': {'pg': 'p1', 'x': 10, 'y': 20},
      });
      final presence = await a.waitFor('presence', 1);
      expect(presence.single['user'], 'bob');
      expect((presence.single['d'] as Map)['x'], 10);

      // it's listed among bob's notes, not as his own
      (_, body) = await request('GET', '/notes', token: bobToken);
      expect(body['notes'], isEmpty);
      expect(body['shared'], [
        {'token': link, 'path': '/Maths', 'owner': 'alice', 'head': 2},
      ]);

      // once alice stops sharing it, bob is disconnected and can't come back
      await request(
        'POST',
        '/notes/unshare',
        token: token,
        body: {'path': '/Maths'},
      );
      await b.waitFor('deleted', 1);
      (_, body) = await request('GET', '/notes', token: bobToken);
      expect(body['shared'], isEmpty);
      final b2 = await _TestClient.connect(server, bobToken)
        ..join('ignored', 'b', share: link);
      await b2.waitFor('deleted', 1);
    });

    test('keeps the latest favorite and cover of each note', () async {
      var (status, body) = await request(
        'POST',
        '/library',
        token: token,
        body: {
          'entries': {
            '/a': {'f': true, 'c': 2, 't': 10},
            '/b': {'f': false, 'c': 1, 't': 10},
          },
        },
      );
      expect(status, 200);

      // an older change from another device is ignored
      (status, body) = await request(
        'POST',
        '/library',
        token: token,
        body: {
          'entries': {
            '/a': {'f': false, 'c': -1, 't': 5},
            '/b': {'f': true, 'c': 1, 't': 20},
          },
        },
      );
      final entries = body['entries'] as Map;
      expect(entries['/a'], {'f': true, 'c': 2, 't': 10});
      expect(entries['/b'], {'f': true, 'c': 1, 't': 20});

      await server.stop();
      await startServer();
      (status, body) = await request('GET', '/library', token: token);
      expect(body['entries'], entries);

      // other accounts don't see it
      final bob = await register('bob');
      (status, body) = await request('GET', '/library', token: bob);
      expect(body['entries'], isEmpty);
    });

    test('a deleted note is deleted for the other devices', () async {
      final a = await _TestClient.connect(server, token)
        ..join('/note', 'a');
      final b = await _TestClient.connect(server, token)
        ..join('/note', 'b');
      await Future.wait([a.waitFor('synced', 1), b.waitFor('synced', 1)]);
      a.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 1},
      });
      await a.waitFor('ack', 1);

      final (status, _) = await request(
        'POST',
        '/notes/delete',
        token: token,
        body: {'path': '/note'},
      );
      expect(status, 200);
      await b.waitFor('deleted', 1);

      final (_, list) = await request('GET', '/notes', token: token);
      expect(list, {
        'notes': <Object>[],
        'deleted': ['/note'],
        'shared': <dynamic>[],
      });

      // a device that had the note is told that it was deleted
      final c = await _TestClient.connect(server, token)
        ..join('/note', 'c', since: 1);
      await c.waitFor('deleted', 1);
      expect(c.messages.where((message) => message['k'] == 'synced'), isEmpty);

      // but a new note can take its name
      final d = await _TestClient.connect(server, token)
        ..join('/note', 'd', create: true);
      final synced = await d.waitFor('synced', 1);
      expect(_int(synced.single['head']), 0);
      d.send({
        'k': 'op',
        'cid': 1,
        'd': {'n': 2},
      });
      await d.waitFor('ack', 1);
      expect((await request('GET', '/notes', token: token)).$2, {
        'notes': [
          {'path': '/note', 'head': 1},
        ],
        'deleted': <String>[],
        'shared': <dynamic>[],
      });
    });
  });
}
