import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A note that its owner shares with whoever has its link.
typedef Share = ({String owner, String path});

/// The links that give other accounts access to notes, and the notes that
/// each account has opened from a link.
///
/// A link is a random token. Anyone signed in to the server who has it can
/// open the note and edit it, until its owner stops sharing it.
class ShareStore {
  new(this.file);

  final File file;

  /// The note that each token gives access to.
  final _shares = <String, Share>{};

  /// The tokens of the shared notes that each user has opened.
  final _accepted = <String, Set<String>>{};

  Future<void> _lastSave = Future.value();

  static final _random = Random.secure();

  Future<void> load() async {
    if (!file.existsSync()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (final MapEntry(key: token, value: share)
        in (json['shares'] as Map<String, dynamic>).entries) {
      final map = share as Map<String, dynamic>;
      _shares[token] = (owner: map['owner'] as String, path: map['path'] as String);
    }
    for (final MapEntry(key: user, value: tokens)
        in (json['accepted'] as Map<String, dynamic>).entries) {
      _accepted[user] = (tokens as List).cast<String>().toSet();
    }
  }

  Future<void> _save() => _lastSave = _lastSave.then((_) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'shares': {
          for (final MapEntry(key: token, value: share) in _shares.entries)
            token: {'owner': share.owner, 'path': share.path},
        },
        'accepted': {
          for (final MapEntry(key: user, value: tokens) in _accepted.entries)
            user: tokens.toList(),
        },
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  });

  Share? operator [](String? token) => token == null ? null : _shares[token];

  /// Returns the token of the note at [path] of [owner],
  /// creating one if the note isn't shared yet.
  Future<String> share(String owner, String path) async {
    if (tokenOf(owner, path) case final token?) return token;
    final token = base64Url
        .encode(List.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _shares[token] = (owner: owner, path: path);
    await _save();
    return token;
  }

  String? tokenOf(String owner, String path) {
    for (final MapEntry(key: token, value: share) in _shares.entries) {
      if (share.owner == owner && share.path == path) return token;
    }
    return null;
  }

  /// Stops sharing the note at [path] of [owner], and returns its token.
  Future<String?> unshare(String owner, String path) async {
    final token = tokenOf(owner, path);
    if (token == null) return null;
    _shares.remove(token);
    for (final tokens in _accepted.values) {
      tokens.remove(token);
    }
    await _save();
    return token;
  }

  /// Takes note that [user] opened the note shared as [token].
  Future<void> accept(String user, String token) async {
    final share = _shares[token];
    if (share == null || share.owner == user) return;
    if ((_accepted[user] ??= {}).add(token)) await _save();
  }

  Future<void> leave(String user, String token) async {
    if (_accepted[user]?.remove(token) ?? false) await _save();
  }

  /// The tokens of the notes that [user] opened from a link.
  Iterable<String> acceptedBy(String user) => [
    for (final token in _accepted[user] ?? const <String>{})
      if (_shares.containsKey(token)) token,
  ];

  /// Call this when the owner renamed a note, so that its link keeps working.
  Future<void> renamed(String owner, String fromPath, String toPath) async {
    final token = tokenOf(owner, fromPath);
    if (token == null) return;
    _shares[token] = (owner: owner, path: toPath);
    await _save();
  }
}
