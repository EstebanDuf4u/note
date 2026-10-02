import 'dart:io';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteplus_server/relay_server.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ids.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/data/sync/realtime/realtime_session.dart';
import 'package:sbn/change.dart';

/// The session of the account that the devices are signed in to.
var _token = '';

/// A copy of a note on one device,
/// with the parts of the editor that realtime sync relies on.
class _Device {
  new(this.name, {EditorCoreInfo? coreInfo})
    : coreInfo = coreInfo ?? EditorCoreInfo(filePath: '/note') {
    if (this.coreInfo.pages.isEmpty) createPage(-1);
  }

  final String name;
  final EditorCoreInfo coreInfo;
  RealtimeSession? session;
  var remoteChanges = 0;

  late final applier = NoteOpApplier(
    coreInfo: coreInfo,
    createPage: createPage,
    removeExcessPages: removeExcessPages,
  );

  List<EditorPage> get pages => coreInfo.pages;

  /// Same as [EditorState.createPage].
  void createPage(int pageIndex) {
    while (pageIndex >= pages.length - 1) {
      pages.add(EditorPage());
      coreInfo.assignPageIds();
    }
  }

  /// Same as [EditorState.removeExcessPages], without the scrolling.
  void removeExcessPages() {
    for (int i = pages.length - 1; i >= 1; --i) {
      if (pages[i].isEmpty && pages[i - 1].isEmpty) {
        pages.removeAt(i).dispose();
      } else {
        break;
      }
    }
  }

  void connect(RelayServer server, {String room = '/note'}) {
    session = RealtimeSession(
      serverUrl: 'ws://127.0.0.1:${server.port}',
      token: _token,
      room: room,
      clientId: name,
      applier: applier,
      onRemoteChange: () => remoteChanges++,
      onLocalStateChange: () {},
      minReconnectDelay: const Duration(milliseconds: 50),
    )..start();
  }

  /// Records [item] as the editor would, and returns its operations.
  List<NoteOp> record(EditorHistoryItem item, {bool inverse = false}) {
    final ops = NoteOps.fromHistoryItem(item, coreInfo, inverse: inverse);
    session?.submit(ops);
    return ops;
  }

  Stroke draw(int pageIndex, {Offset at = .zero, Color color = Colors.black}) {
    final page = pages[pageIndex];
    final stroke =
        Stroke(
            color: color,
            pressureEnabled: true,
            options: StrokeOptions(),
            pageIndex: pageIndex,
            page: page,
            toolId: .fountainPen,
          )
          ..addPoint(at, 0.5)
          ..addPoint(at + const Offset(10, 5), 0.6)
          ..addPoint(at + const Offset(20, 0), 0.4);
    createPage(pageIndex);
    page.insertStroke(stroke);
    lastOps = record(
      EditorHistoryItem(
        type: .draw,
        pageIndex: pageIndex,
        strokes: [stroke],
        images: [],
      ),
    );
    return stroke;
  }

  void erase(List<Stroke> strokes) {
    for (final page in pages) {
      page.strokes.removeWhere(strokes.contains);
    }
    removeExcessPages();
    lastOps = record(
      EditorHistoryItem(
        type: .erase,
        pageIndex: 0,
        strokes: strokes,
        images: [],
      ),
    );
  }

  void move(List<Stroke> strokes, Offset offset) {
    for (final stroke in strokes) {
      stroke.shift(offset);
    }
    lastOps = record(
      EditorHistoryItem(
        type: .move,
        pageIndex: 0,
        strokes: strokes,
        images: [],
        offset: .fromLTRB(offset.dx, offset.dy, offset.dx, offset.dy),
      ),
    );
  }

  void recolor(List<Stroke> strokes, Color color) {
    final colorChange = {
      for (final stroke in strokes)
        stroke: Change(previous: stroke.color, current: color),
    };
    for (final stroke in strokes) {
      stroke.color = color;
    }
    lastOps = record(
      EditorHistoryItem(
        type: .changeColor,
        pageIndex: 0,
        strokes: strokes,
        images: [],
        colorChange: colorChange,
      ),
    );
  }

  EditorPage insertPageAfter(int pageIndex) {
    final page = EditorPage(id: newId());
    pages.insert(pageIndex + 1, page);
    lastOps = record(
      EditorHistoryItem(
        type: .insertPage,
        pageIndex: pageIndex + 1,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
    return page;
  }

  void deletePage(int pageIndex) {
    final page = pages.removeAt(pageIndex);
    createPage(pageIndex - 1);
    lastOps = record(
      EditorHistoryItem(
        type: .deletePage,
        pageIndex: pageIndex,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
  }

  /// The operations of the last change made on this device.
  List<NoteOp> lastOps = [];

  /// Applies [ops] as if they were received from another device.
  void receive(List<NoteOp> ops) {
    // Operations are sent as bson, so send them through it here too
    for (final op in ops) {
      applier.apply(_throughBson(op));
    }
  }

  /// A description of the note that should be equal on all devices.
  List<String> get contents => [
    for (final page in pages)
      '${page.id} ${page.size.width.round()}x${page.size.height.round()}: '
          '${page.strokes.map(_describeStroke).join(' ')}',
  ];

  static String _describeStroke(Stroke stroke) {
    final bounds = stroke.lowQualityPath.getBounds();
    return '${stroke.id}@${bounds.left.round()},${bounds.top.round()}'
        '#${stroke.color.toARGB32().toRadixString(16)}';
  }

  /// Reloads the note from its saved form, as if the app was restarted.
  Future<_Device> restarted() async {
    final (bson, _) = coreInfo.saveToBinary(currentPageIndex: null);
    return _Device(
      name,
      coreInfo: await EditorCoreInfo.loadFromFileContents(
        bsonBytes: bson,
        path: coreInfo.filePath,
        onlyFirstPage: false,
      ),
    );
  }
}

NoteOp _throughBson(NoteOp op) =>
    BsonCodec.deserialize(BsonBinary.from(BsonCodec.serialize(op).byteList));

Future<void> _until(bool Function() condition, {String? reason}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 10)) {
      fail('Timed out waiting${reason == null ? '' : ' for $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  group('Operations', () {
    test('a stroke keeps its id when saved', () async {
      final a = _Device('a');
      final stroke = a.draw(0);
      final reloaded = await a.restarted();
      expect(reloaded.pages.first.strokes.single.id, stroke.id);
      expect(reloaded.pages.map((page) => page.id), a.pages.map((p) => p.id));
    });

    test('devices agree on the ids of automatically created pages', () {
      final a = _Device('a'), b = _Device('b');
      a.createPage(3);
      b.createPage(3);
      expect(a.pages.map((page) => page.id), b.pages.map((page) => page.id));
      expect(a.pages.map((page) => page.id).toSet(), hasLength(a.pages.length));
    });

    test('draw, move, recolor and erase', () {
      final a = _Device('a'), b = _Device('b');

      final s1 = a.draw(0);
      b.receive(a.lastOps);
      final s2 = a.draw(1, at: const Offset(50, 50));
      b.receive(a.lastOps);
      expect(b.contents, a.contents);
      expect(b.pages, hasLength(3), reason: 'Should add a blank last page');

      a.move([s1, s2], const Offset(30, -5));
      b.receive(a.lastOps);
      a.recolor([s1], Colors.red);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);

      a.erase([s2]);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);
      expect(b.pages, hasLength(2), reason: 'Should remove the excess page');

      // receiving an operation twice doesn't change anything
      b.receive(a.lastOps);
      expect(b.contents, a.contents);
    });

    test('undoing sends the opposite operations', () {
      final a = _Device('a'), b = _Device('b');
      final stroke = a.draw(0);
      b.receive(a.lastOps);

      final item = EditorHistoryItem(
        type: .draw,
        pageIndex: 0,
        strokes: [stroke],
        images: [],
      );
      a.pages[0].strokes.remove(stroke);
      a.removeExcessPages();
      b.receive(a.record(item, inverse: true));
      expect(b.pages.first.strokes, isEmpty);
      expect(b.contents, a.contents);
    });

    test('inserting and deleting pages', () {
      final a = _Device('a'), b = _Device('b');
      a.draw(0);
      b.receive(a.lastOps);

      a.insertPageAfter(0);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);

      // a draws on its last page, whose id b doesn't know
      a.draw(2);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);

      a.deletePage(1);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);
    });

    test('a page is inserted while another device draws', () {
      final a = _Device('a'), b = _Device('b');
      a.draw(0);
      b.receive(a.lastOps);

      // at the same time...
      a.insertPageAfter(0);
      final insertOps = a.lastOps;
      b.draw(1);
      final drawOps = b.lastOps;

      a.receive(drawOps);
      b.receive(insertOps);
      expect(b.contents, a.contents);
    });

    test('the same strokes are moved on two devices at once', () {
      final a = _Device('a'), b = _Device('b');
      final sa = a.draw(0);
      b.receive(a.lastOps);
      final sb = b.pages.first.strokes.single;

      a.move([sa], const Offset(10, 0));
      b.move([sb], const Offset(0, 20));
      a.receive(b.lastOps);
      b.receive(a.lastOps);
      expect(b.contents, a.contents);
    });

    test('a snapshot recreates the note', () {
      final a = _Device('a'), b = _Device('b');
      a.draw(0);
      a.insertPageAfter(0);
      a.draw(2, at: const Offset(5, 5));

      b.receive(NoteOps.snapshot(a.coreInfo));
      expect(b.contents, a.contents);
    });
  });

  group('Session', () {
    late Directory dataDirectory;
    late RelayServer server;
    final devices = <_Device>[];

    _Device device(String name, {String room = '/note'}) {
      final device = _Device(name)..connect(server, room: room);
      devices.add(device);
      return device;
    }

    Future<void> live(_Device device) =>
        _until(() => device.session!.state.value == .live, reason: 'live');

    Future<void> inSync(_Device a, _Device b) => _until(
      () =>
          a.coreInfo.pendingOps.isEmpty &&
          b.coreInfo.pendingOps.isEmpty &&
          a.contents.toString() == b.contents.toString(),
      reason: 'the devices to have the same note',
    );

    setUp(() async {
      // let the tests use real sockets
      HttpOverrides.global = null;
      dataDirectory = await Directory.systemTemp.createTemp('noteplus_test');
      server = RelayServer(
        dataDirectory: dataDirectory,
        passwordIterations: 10,
      );
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      final (_, token) = await server.accounts.register('tester', 'password');
      _token = token;
    });
    tearDown(() async {
      for (final device in devices) {
        device.session?.dispose();
      }
      devices.clear();
      await server.stop();
      await dataDirectory.delete(recursive: true);
    });

    test('changes appear on the other device as they happen', () async {
      final a = device('a'), b = device('b');
      await Future.wait([live(a), live(b)]);

      final stroke = a.draw(0);
      await inSync(a, b);
      expect(b.pages.first.strokes.single.id, stroke.id);
      expect(b.remoteChanges, greaterThan(0));

      b.move([b.pages.first.strokes.single], const Offset(40, 40));
      b.draw(1);
      await inSync(a, b);
      expect(a.pages[1].strokes, hasLength(1));

      a.erase([stroke]);
      await inSync(a, b);
      expect(b.pages.first.strokes, isEmpty);
    });

    test('two devices write on the same page at once', () async {
      final a = device('a'), b = device('b');
      await Future.wait([live(a), live(b)]);

      for (int i = 0; i < 5; ++i) {
        a.draw(0, at: Offset(i * 10, 0));
        b.draw(0, at: Offset(i * 10, 100));
        a.recolor([a.pages.first.strokes.first], Colors.blue);
        b.recolor([b.pages.first.strokes.first], Colors.green);
      }
      await inSync(a, b);
      expect(a.pages.first.strokes, hasLength(10));
    });

    test('devices in other notes are not affected', () async {
      final a = device('a'), other = device('c', room: '/other');
      await Future.wait([live(a), live(other)]);
      a.draw(0);
      await _until(() => a.coreInfo.pendingOps.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(other.pages.first.strokes, isEmpty);
    });

    test('an existing note is shared when it first connects', () async {
      final a = _Device('a');
      devices.add(a);
      a.draw(0);
      a.draw(1);
      expect(a.coreInfo.realtimeSeq, isNull);

      a.connect(server);
      final b = device('b');
      await inSync(a, b);
      expect(b.pages[1].strokes, hasLength(1));
      expect(a.coreInfo.realtimeSeq, isNotNull);
    });

    test('two existing notes are merged', () async {
      final a = _Device('a'), b = _Device('b');
      devices.addAll([a, b]);
      a.draw(0);
      b.draw(0, at: const Offset(100, 100));

      a.connect(server);
      await live(a);
      await _until(() => a.coreInfo.pendingOps.isEmpty);
      b.connect(server);
      await inSync(a, b);
      expect(a.pages.first.strokes, hasLength(2));
    });

    test('offline changes are sent after reconnecting', () async {
      final a = device('a'), b = device('b');
      await Future.wait([live(a), live(b)]);
      a.draw(0);
      await inSync(a, b);

      // the server goes away
      final port = server.port;
      await server.stop();
      await _until(() => a.session!.state.value == .offline);
      await _until(() => b.session!.state.value == .offline);

      final offlineStroke = a.draw(0, at: const Offset(200, 200));
      a.move([offlineStroke], const Offset(0, 50));
      b.draw(1);
      expect(a.coreInfo.pendingOps, hasLength(2));

      server = RelayServer(dataDirectory: dataDirectory);
      await server.start(address: InternetAddress.loopbackIPv4, port: port);
      await inSync(a, b);
      expect(a.pages[0].strokes, hasLength(2));
      expect(a.pages[1].strokes, hasLength(1));
    });

    test('offline changes survive restarting the app', () async {
      var a = device('a');
      final b = device('b');
      await Future.wait([live(a), live(b)]);
      a.draw(0);
      await inSync(a, b);

      // a goes offline, makes a change, and is closed
      a.session!.dispose();
      a.session = null;
      final stroke = a.pages.first.strokes.single;
      a.coreInfo.pendingOps.add({
        'cid': DateTime.now().microsecondsSinceEpoch,
        'd': NoteOps.moveStrokes([stroke], const Offset(25, 25)),
      });
      stroke.shift(const Offset(25, 25));
      final seq = a.coreInfo.realtimeSeq;

      // meanwhile b keeps writing
      b.draw(0, at: const Offset(300, 0));
      await _until(() => b.coreInfo.pendingOps.isEmpty);

      a = await a.restarted();
      devices.add(a);
      expect(a.coreInfo.realtimeSeq, seq);
      expect(a.coreInfo.pendingOps, hasLength(1));

      a.connect(server);
      await inSync(a, b);
      expect(a.pages.first.strokes, hasLength(2));
    });

    test('a renamed note is shared again under its new name', () async {
      final a = device('a');
      await live(a);
      a.draw(0);
      await _until(() => a.coreInfo.pendingOps.isEmpty);
      // the new room starts at 0, so it's behind this note
      expect(a.coreInfo.realtimeSeq, greaterThan(0));

      a.session!.dispose();
      a.connect(server, room: '/renamed');
      final b = device('b', room: '/renamed');
      await inSync(a, b);
      expect(b.pages.first.strokes, hasLength(1));
    });
  });
}
