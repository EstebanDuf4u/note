import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Why a request about an account was refused.
class AccountException implements Exception {
  const new(this.code, this.status);

  /// A short identifier that the app translates, e.g. `username_taken`.
  final String code;

  /// The HTTP status to answer with.
  final int status;

  @override
  String toString() => 'AccountException($code)';
}

final _random = Random.secure();

Uint8List _randomBytes(int length) =>
    Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// PBKDF2 with HMAC-SHA256, returning one block (32 bytes).
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (int i = 1; i < iterations; ++i) {
    block = hmac.convert(block).bytes;
    for (int j = 0; j < result.length; ++j) {
      result[j] ^= block[j];
    }
  }
  return result;
}

/// Hashes [password] on another isolate, since it's slow by design
/// and the server shouldn't stop relaying operations meanwhile.
Future<Uint8List> _hashPassword(
  String password,
  Uint8List salt,
  int iterations,
) => Isolate.run(() => pbkdf2(utf8.encode(password), salt, iterations));

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (int i = 0; i < a.length; ++i) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

class _User {
  new({
    required this.id,
    required this.name,
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  factory fromJson(Map<String, dynamic> json) => _User(
    id: json['id'] as String,
    name: json['name'] as String,
    salt: base64.decode(json['salt'] as String),
    hash: base64.decode(json['hash'] as String),
    iterations: json['iterations'] as int,
  );

  /// Never changes, and is safe to use as a directory name.
  final String id;

  /// The username as the user typed it when registering.
  final String name;

  final Uint8List salt, hash;
  final int iterations;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'salt': base64.encode(salt),
    'hash': base64.encode(hash),
    'iterations': iterations,
  };
}

/// The accounts of the people who use this server, and their sessions.
///
/// Passwords are stored as salted PBKDF2 hashes. A session is a random token
/// given to a device when it signs in; only its hash is stored.
class AccountStore {
  new(this.file, {this.passwordIterations = 100000});

  final File file;

  /// How many PBKDF2 iterations to use for new passwords.
  final int passwordIterations;

  static const maxFailedLogins = 10;
  static const failedLoginWindow = Duration(minutes: 10);

  static final _usernameRegex = RegExp(r'^[a-zA-Z0-9._-]{3,32}$');
  static const minPasswordLength = 8;
  static const maxPasswordLength = 256;

  /// The users by their lowercased name.
  final _users = <String, _User>{};

  /// The id of the signed in user for the hash of each session token.
  final _sessions = <String, String>{};

  /// When each username recently failed to sign in.
  final _failedLogins = <String, List<DateTime>>{};

  Future<void> _lastSave = Future.value();

  Future<void> load() async {
    _users.clear();
    _sessions.clear();
    if (!file.existsSync()) return;

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (final user in json['users'] as List) {
      final parsed = _User.fromJson(user as Map<String, dynamic>);
      _users[parsed.name.toLowerCase()] = parsed;
    }
    (json['sessions'] as Map<String, dynamic>).forEach((tokenHash, userId) {
      _sessions[tokenHash] = userId as String;
    });
  }

  /// Writes the accounts to disk, one write at a time.
  Future<void> _save() {
    final contents = jsonEncode({
      'users': _users.values.map((user) => user.toJson()).toList(),
      'sessions': _sessions,
    });
    return _lastSave = _lastSave.catchError((Object _) {}).then((_) async {
      // write to another file first so a crash can't leave it half written
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(file.path);
    });
  }

  static String _hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  Future<String> _newSession(_User user) async {
    final token = base64Url.encode(_randomBytes(32));
    _sessions[_hashToken(token)] = user.id;
    await _save();
    return token;
  }

  /// Creates an account and returns the name it was registered with,
  /// and a session token.
  Future<(String name, String token)> register(
    String username,
    String password,
  ) async {
    if (!_usernameRegex.hasMatch(username)) {
      throw const AccountException('invalid_username', HttpStatus.badRequest);
    }
    if (password.length < minPasswordLength ||
        password.length > maxPasswordLength) {
      throw const AccountException('weak_password', HttpStatus.badRequest);
    }
    final key = username.toLowerCase();
    if (_users.containsKey(key)) {
      throw const AccountException('username_taken', HttpStatus.conflict);
    }

    final salt = _randomBytes(16);
    final hash = await _hashPassword(password, salt, passwordIterations);
    // someone else may have taken the name while we were hashing
    if (_users.containsKey(key)) {
      throw const AccountException('username_taken', HttpStatus.conflict);
    }

    final user = _users[key] = _User(
      id: _hex(_randomBytes(12)),
      name: username,
      salt: salt,
      hash: hash,
      iterations: passwordIterations,
    );
    return (user.name, await _newSession(user));
  }

  /// Returns the user's name and a new session token.
  Future<(String name, String token)> login(
    String username,
    String password,
  ) async {
    final key = username.toLowerCase();
    final now = DateTime.now();
    final failures = _failedLogins[key] ??= [];
    failures.removeWhere((time) => now.difference(time) > failedLoginWindow);
    if (failures.length >= maxFailedLogins) {
      throw const AccountException(
        'too_many_attempts',
        HttpStatus.tooManyRequests,
      );
    }

    final user = _users[key];
    // Hash even if there's no such user,
    // so that the response time doesn't reveal which usernames exist.
    final hash = await _hashPassword(
      password.length > maxPasswordLength ? '' : password,
      user?.salt ?? Uint8List(16),
      user?.iterations ?? passwordIterations,
    );
    if (user == null || !_constantTimeEquals(hash, user.hash)) {
      failures.add(now);
      throw const AccountException(
        'wrong_credentials',
        HttpStatus.unauthorized,
      );
    }

    _failedLogins.remove(key);
    return (user.name, await _newSession(user));
  }

  /// Ends the session of [token].
  Future<void> logout(String token) async {
    if (_sessions.remove(_hashToken(token)) != null) await _save();
  }

  /// Returns the id of the user that [token] was given to,
  /// or null if it isn't a session token.
  String? userIdFor(String? token) {
    if (token == null || token.isEmpty) return null;
    return _sessions[_hashToken(token)];
  }
}
