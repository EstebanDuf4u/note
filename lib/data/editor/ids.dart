import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// Returns a random id that is unique across devices,
/// used to address strokes and pages when syncing in realtime.
String newId() {
  final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
  return base64Url.encode(bytes);
}

/// The id of the first page of every note.
const firstPageId = 'p0';

/// Returns the id of the page that is automatically appended
/// after the page with id [previousPageId].
///
/// This is deterministic so that devices which each append their own
/// blank page at the end of a note agree on its id.
String derivePageId(String previousPageId) {
  final digest = sha256.convert(utf8.encode(previousPageId));
  return 'p${base64Url.encode(digest.bytes.sublist(0, 9))}';
}
