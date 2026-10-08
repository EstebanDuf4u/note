import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/note_library.dart';
import 'package:saber/data/prefs.dart';

/// Why the server refused a request, or couldn't be asked.
class RealtimeAccountException implements Exception {
  const new(this.code);

  /// Either an error code from the server (e.g. `wrong_credentials`),
  /// [invalidServer] or [unreachable].
  final String code;

  static const invalidServer = 'invalid_server';
  static const unreachable = 'unreachable';
  static const unauthorized = 'unauthorized';

  @override
  String toString() => 'RealtimeAccountException($code)';
}

/// The notes of the account, as listed by the server.
class RemoteNotes {
  const new({required this.heads, required this.deleted});

  /// The number of operations of each note, by the note's path.
  final Map<String, int> heads;

  /// The paths of the notes that were deleted on one of the devices.
  final Set<String> deleted;
}

/// The Note+ account that this device is signed in to.
///
/// The account lives on a Note+ server (see the `server` directory),
/// which keeps the account's notes in sync between its devices.
abstract final class RealtimeAccount {
  static final log = Logger('RealtimeAccount');

  static const _timeout = Duration(seconds: 15);

  static bool get isSignedIn =>
      stows.realtimeToken.value.isNotEmpty &&
      stows.realtimeUrl.value.isNotEmpty;

  /// Waits until [isSignedIn] can be read.
  static Future<void> waitUntilLoaded() => Future.wait([
    stows.realtimeUrl.waitUntilRead(),
    stows.realtimeUsername.waitUntilRead(),
    stows.realtimeToken.waitUntilRead(),
    stows.realtimeClientId.waitUntilRead(),
    stows.realtimePendingDeletes.waitUntilRead(),
    stows.realtimeNoteSeqs.waitUntilRead(),
  ]);

  /// Returns the address of the server that the user meant by [input],
  /// e.g. `http://192.168.1.10:8787` for `192.168.1.10:8787`.
  ///
  /// Throws a [RealtimeAccountException] if [input] isn't an address.
  static String normalizeServerUrl(String input) {
    const invalid = RealtimeAccountException(
      RealtimeAccountException.invalidServer,
    );
    input = input.trim();
    if (input.isEmpty) throw invalid;

    if (!input.contains('://')) {
      // Servers on the local network are rarely set up with https.
      final host = input.split('/').first.split(':').first;
      final isLocal =
          host == 'localhost' ||
          host.endsWith('.local') ||
          InternetAddress.tryParse(host) != null;
      input = '${isLocal ? 'http' : 'https'}://$input';
    }

    final uri = Uri.tryParse(input);
    if (uri == null || uri.host.isEmpty) throw invalid;
    final scheme = switch (uri.scheme) {
      'http' || 'ws' => 'http',
      'https' || 'wss' => 'https',
      _ => throw invalid,
    };
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  /// The address that notes are synced through.
  static String get webSocketUrl {
    final uri = Uri.parse(stows.realtimeUrl.value);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws').toString();
  }

  /// Sends a request to [server], and returns the json in its response.
  static Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    required String server,
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final http.Response response;
    try {
      final request = http.Request(method, Uri.parse('$server$path'));
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      response = await http.Response.fromStream(await request.send())
          .timeout(_timeout);
    } catch (e) {
      log.info('$method $path failed: $e');
      throw const RealtimeAccountException(
        RealtimeAccountException.unreachable,
      );
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      // something answered, but it isn't a Note+ server
      throw const RealtimeAccountException(
        RealtimeAccountException.invalidServer,
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw RealtimeAccountException(
        json['error'] as String? ?? RealtimeAccountException.invalidServer,
      );
    }
    return json;
  }

  /// Sends a request as the signed in user.
  static Future<Map<String, dynamic>> _authorizedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = stows.realtimeToken.value;
    try {
      return await _request(
        method,
        path,
        server: stows.realtimeUrl.value,
        token: token,
        body: body,
      );
    } on RealtimeAccountException catch (e) {
      if (e.code == RealtimeAccountException.unauthorized) {
        sessionEnded(token);
      }
      rethrow;
    }
  }

  /// Signs in to the account [username] on [server],
  /// or creates that account if [register] is true.
  ///
  /// Throws a [RealtimeAccountException] if that fails.
  static Future<void> signIn({
    required String server,
    required String username,
    required String password,
    required bool register,
  }) async {
    await waitUntilLoaded();
    final url = normalizeServerUrl(server);

    final info = await _request('GET', '/', server: url);
    if (info['server'] != 'noteplus') {
      throw const RealtimeAccountException(
        RealtimeAccountException.invalidServer,
      );
    }

    final response = await _request(
      'POST',
      register ? '/register' : '/login',
      server: url,
      body: {'username': username.trim(), 'password': password},
    );
    final name = response['username'] as String;

    if (url != stows.realtimeUrl.value ||
        name != stows.realtimeUsername.value) {
      _forgetSyncState();
    }
    if (stows.realtimeClientId.value.isEmpty) {
      stows.realtimeClientId.value = newId();
    }
    stows.realtimeUrl.value = url;
    stows.realtimeUsername.value = name;
    stows.realtimeToken.value = response['token'] as String;
  }

  /// Signs out of the account. The notes stay on this device.
  static Future<void> signOut() async {
    if (!isSignedIn) return;
    final token = stows.realtimeToken.value;
    stows.realtimeToken.value = '';
    try {
      await _request(
        'POST',
        '/logout',
        server: stows.realtimeUrl.value,
        token: token,
      );
    } on RealtimeAccountException catch (e) {
      // The session stays valid on the server, but this device forgot it.
      log.info('Failed to tell the server that we signed out: $e');
    }
  }

  /// Call this when the server says that the session [token] isn't valid,
  /// e.g. because the account was removed, so that the user signs in again.
  static void sessionEnded(String token) {
    if (stows.realtimeToken.value == token) stows.realtimeToken.value = '';
  }

  /// What we know about the notes on the server isn't true of another account.
  static void _forgetSyncState() {
    stows.realtimePendingDeletes.value = [];
    stows.realtimeNoteSeqs.value = '{}';
    // everything is sent to the new account
    stows.noteLibraryUnsent.value = NoteLibrary.allPaths;
    NoteLibrary.forgetChangeTimes();
  }

  static Future<RemoteNotes> fetchNotes() async {
    final json = await _authorizedRequest('GET', '/notes');
    return RemoteNotes(
      heads: {
        for (final note in json['notes'] as List)
          (note as Map)['path'] as String: (note['head'] as num).toInt(),
      },
      deleted: (json['deleted'] as List).cast<String>().toSet(),
    );
  }

  /// Deletes the note at [path] from the account,
  /// so that the user's other devices delete it too.
  static Future<void> deleteNote(String path) =>
      _authorizedRequest('POST', '/notes/delete', body: {'path': path});

  /// Sends the [changes] to the favorites and covers made on this device,
  /// and returns those of the whole account.
  static Future<Map<String, dynamic>> syncLibrary(
    Map<String, Map<String, dynamic>> changes,
  ) async {
    final json = changes.isEmpty
        ? await _authorizedRequest('GET', '/library')
        : await _authorizedRequest(
            'POST',
            '/library',
            body: {'entries': changes},
          );
    return Map<String, dynamic>.from(json['entries'] as Map);
  }
}
