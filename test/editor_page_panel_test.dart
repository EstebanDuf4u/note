import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/toolbar/editor_page_panel.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  testWidgets('Editor: the page panel shows every page and jumps to one', (
    tester,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    FlavorConfig.setup();
    await tester.runAsync(FileManager.init);
    stows.editorPagePanel.value = false;
    addTearDown(() => stows.editorPagePanel.value = false);

    await tester.pumpWidget(
      TranslationProvider(
        child: ScreenshotApp(
          device: GoldenScreenshotDevices.flathub.device,
          home: Editor(),
        ),
      ),
    );
    final editorState = tester.state<EditorState>(find.byType(Editor));
    addTearDown(editorState.cancelAutosaveAndMarkSaved);
    await tester.pump();

    editorState.insertPageAfter(0);
    editorState.insertPageAfter(1);
    await tester.pump();
    final pageCount = editorState.coreInfo.pages.length;
    expect(pageCount, greaterThanOrEqualTo(3));
    expect(find.byType(EditorPagePanel), findsNothing);

    // show the panel
    await tester.tap(find.byTooltip(t.editor.pagePanel));
    await tester.pump();
    expect(stows.editorPagePanel.value, isTrue);
    expect(find.byType(EditorPagePanel), findsOneWidget);
    expect(find.byType(CanvasPreview), findsNWidgets(pageCount));

    /// Whether the thumbnail of the page numbered [number] is highlighted.
    bool isHighlighted(String number) =>
        tester
            .widget<Text>(
              find.descendant(
                of: find.byType(EditorPagePanel),
                matching: find.text(number),
              ),
            )
            .style
            ?.fontWeight ==
        FontWeight.bold;
    expect(isHighlighted('1'), isTrue);
    expect(isHighlighted('3'), isFalse);
    final scrollBefore = editorState.scrollY;

    // jump to the third page
    await tester.tap(
      find.descendant(
        of: find.byType(EditorPagePanel),
        matching: find.text('3'),
      ),
    );
    await tester.pump();
    expect(editorState.scrollY, lessThan(scrollBefore));
    expect(isHighlighted('3'), isTrue);
    expect(isHighlighted('1'), isFalse);

    // hide the panel
    await tester.tap(find.byTooltip(t.editor.pagePanel));
    await tester.pump();
    expect(find.byType(EditorPagePanel), findsNothing);
  });
}
