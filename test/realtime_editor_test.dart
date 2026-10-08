import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:noteplus_server/relay_server.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

/// A 1x1 png.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// A second device, which only speaks the realtime protocol.
class _OtherDevice {
  new(this.socket, this.token) {
    socket.listen((data) {
      messages.add(BsonCodec.deserialize(BsonBinary.from(data as List<int>)));
    });
  }

  final WebSocket socket;
  final String token;
  final messages = <Map<String, dynamic>>[];
  var _lastOpId = 0;

  /// The sequence number of the last operation that this device received.
  int get lastSeq => messages
      .where((message) => message['k'] == 'op')
      .map((message) => opInt(message['seq']))
      .fold(0, (a, b) => a > b ? a : b);

  Iterable<NoteOp> get ops => messages
      .where((message) => message['k'] == 'op')
      .map((message) => Map<String, dynamic>.from(message['d'] as Map));

  void _send(Map<String, dynamic> message) =>
      socket.add(BsonCodec.serialize(message).byteList);
  void join(String room) => _send({
    'k': 'join',
    'room': room,
    'client': 'other',
    'since': 0,
    'token': token,
  });
  void sendOp(NoteOp op) => _send({'k': 'op', 'cid': ++_lastOpId, 'd': op});
}

void main() {
  testWidgets('Editor: realtime sync with another device', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    FlavorConfig.setup();
    await tester.runAsync(FileManager.init);

    // let the test use real sockets
    HttpOverrides.global = null;

    final dataDirectory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('noteplus_editor_test'),
    );
    // The server is created in [runAsync] too, since its futures
    // would never complete if they belonged to the test's fake clock.
    final (server, token) = (await tester.runAsync(() async {
      final server = RelayServer(
        dataDirectory: dataDirectory!,
        passwordIterations: 10,
      );
      await server.start(address: InternetAddress.loopbackIPv4, port: 0);
      final (_, token) = await server.accounts.register('tester', 'password');
      return (server, token);
    }))!;

    // sign in
    stows.realtimeUrl.value = 'http://127.0.0.1:${server.port}';
    stows.realtimeUsername.value = 'tester';
    stows.realtimeToken.value = token;
    stows.realtimeClientId.value = 'editor';
    addTearDown(() => stows.realtimeToken.value = '');

    const filePath = '/realtime_editor_test';
    // a previous run may have been interrupted before it could clean up
    final file = FileManager.getFile(filePath + Editor.extension);
    if (file.existsSync()) file.deleteSync();
    await tester.pumpWidget(
      TranslationProvider(
        child: ScreenshotApp(
          device: GoldenScreenshotDevices.androidPhone.device,
          home: Editor(path: filePath),
        ),
      ),
    );
    final editorState = tester.state<EditorState>(find.byType(Editor));
    addTearDown(editorState.cancelAutosaveAndMarkSaved);

    /// Lets real time pass until [condition] is true.
    Future<void> until(bool Function() condition, String reason) async {
      for (int i = 0; i < 500 && !condition(); ++i) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(condition(), isTrue, reason: 'Timed out waiting for $reason');
    }

    await until(
      () => find.byIcon(Icons.cloud_done).evaluate().isNotEmpty,
      'the editor to connect',
    );

    final other = _OtherDevice(
      (await tester.runAsync(
        () => WebSocket.connect('ws://127.0.0.1:${server.port}'),
      ))!,
      token,
    )..join(filePath);
    await until(
      () => other.messages.any((message) => message['k'] == 'synced'),
      'the other device to join',
    );
    // what the editor shared of the new note when it connected
    other.messages.clear();

    // drawing in the editor reaches the other device
    await tester.timedDrag(
      find.byType(Editor),
      const Offset(50, 0),
      const Duration(milliseconds: 100),
    );
    await tester.pump();
    final strokes = editorState.coreInfo.pages.first.strokes;
    expect(strokes, hasLength(1));
    final stroke = strokes.single;
    await until(() => other.ops.isNotEmpty, 'the stroke to be sent');
    expect(other.ops.single['t'], NoteOps.addStrokeType);
    expect((other.ops.single['s'] as Map)['id'], stroke.id);
    expect(other.ops.single['pg'], editorState.coreInfo.pages.first.id);

    // and so does undoing it
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    await until(() => other.ops.length == 2, 'the undo to be sent');
    expect(other.ops.last['t'], NoteOps.removeStrokesType);
    expect(other.ops.last['ids'], [stroke.id]);

    // a stroke from the other device appears in the editor
    final remoteOp = Map<String, dynamic>.from(other.ops.first);
    (remoteOp['s'] as Map)['id'] = 'from-the-other-device';
    other.sendOp(remoteOp);
    await until(() => strokes.isNotEmpty, 'the remote stroke to arrive');
    expect(strokes.single.id, 'from-the-other-device');
    expect(editorState.savingState.value, isNot(SavingState.saved));

    // and it can be erased from here
    other.sendOp({
      't': NoteOps.removeStrokesType,
      'ids': ['from-the-other-device'],
    });
    await until(() => strokes.isEmpty, 'the remote erase to arrive');

    // typing in the editor reaches the other device, a little later
    final page = editorState.coreInfo.pages.first;
    other.messages.clear();
    page.quill.controller.replaceText(0, 0, 'Hello', null);
    await tester.pump();
    await until(() => other.ops.isNotEmpty, 'the text to be sent');
    expect(other.ops.single['t'], NoteOps.textDeltaType);
    expect(other.ops.single['pg'], page.id);
    expect(other.ops.single['d'], [
      {'insert': 'Hello'},
    ]);

    // text from the other device appears in the editor,
    // and isn't something that this device can undo
    final undoableChanges = editorState.history.canUndo;
    other.sendOp({
      't': NoteOps.textDeltaType,
      'pg': page.id,
      'b': other.lastSeq,
      'd': [
        {'retain': 5},
        {'insert': ' from afar'},
      ],
    });
    await until(
      () => page.quill.controller.document.toPlainText() == 'Hello from afar\n',
      'the remote text to arrive',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(editorState.history.canUndo, undoableChanges);
    expect(
      other.ops.where((op) => op['t'] == NoteOps.textDeltaType),
      hasLength(1),
      reason: "The other device's text shouldn't be sent back to it",
    );

    // an image from the other device appears in the editor
    EditorImage.shouldLoadOutImmediately = true;
    addTearDown(() => EditorImage.shouldLoadOutImmediately = false);
    final imageOps = NoteOps.addImage(
      PngEditorImage(
        id: 0,
        extension: '.png',
        imageProvider: MemoryImage(_pngBytes),
        pageIndex: 0,
        pageSize: page.size,
        onMoveImage: null,
        onDeleteImage: null,
        onMiscChange: null,
        assetCache: editorState.coreInfo.assetCache,
        dstRect: const Rect.fromLTWH(100, 100, 200, 200),
        srcRect: const Rect.fromLTWH(0, 0, 1, 1),
        naturalSize: const Size(1, 1),
      ),
      page,
      editorState.coreInfo,
      sentAssets: {},
    );
    imageOps.forEach(other.sendOp);
    await until(() => page.images.isNotEmpty, 'the remote image to arrive');
    final image = page.images.single;
    expect(image.dstRect, const Rect.fromLTWH(100, 100, 200, 200));
    expect(image.onDeleteImage, isNotNull);

    // and deleting it here reaches the other device
    other.messages.clear();
    image.onDeleteImage!(image);
    await tester.pump();
    await until(() => other.ops.isNotEmpty, 'the image removal to be sent');
    expect(other.ops.single['t'], NoteOps.removeImagesType);
    expect(other.ops.single['ids'], [image.uid]);

    // closing the editor exits fullscreen
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => null,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      unawaited(other.socket.close());
      await server.stop();
      await dataDirectory!.delete(recursive: true);
    });
  });
}
