import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:saber/components/home/notebook_cover.dart';
import 'package:saber/components/home/preview_card.dart';
import 'package:saber/components/theming/saber_theme.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/note_library.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/home/browse.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  FlavorConfig.setup();
  setupMockPathProvider();

  setUp(() {
    stows.favoriteNotes.value = [];
    stows.noteCovers.value = '{}';
    stows.noteLibraryChanges.value = '{}';
    stows.noteLibraryUnsent.value = [];
  });

  group('NoteLibrary', () {
    test('changes are synced with the latest one winning', () {
      // set before syncing existed, so older than any synced change
      stows.favoriteNotes.value = ['/old'];
      NoteLibrary.setCover('/a', NoteLibrary.coverColors[3]);
      final unsent = NoteLibrary.unsentChanges;
      expect(unsent.keys, unorderedEquals(['/a', '/old']));
      expect(unsent['/old'], {'f': true, 'c': -1, 't': 1});
      expect(unsent['/a']!['c'], 3);

      // the server has a newer change to /old and an older one to /a,
      // and the user changed /a again meanwhile
      NoteLibrary.setFavorite('/a', true);
      NoteLibrary.applyRemoteChanges({
        '/old': {'f': false, 'c': 5, 't': 2},
        '/a': {'f': false, 'c': -1, 't': 0},
        '/b': {'f': true, 'c': -1, 't': 3},
      }, sent: unsent);
      expect(NoteLibrary.isFavorite('/old'), isFalse);
      expect(NoteLibrary.coverOf('/old'), NoteLibrary.coverColors[5]);
      expect(NoteLibrary.isFavorite('/b'), isTrue);
      expect(NoteLibrary.isFavorite('/a'), isTrue);
      expect(NoteLibrary.coverOf('/a'), NoteLibrary.coverColors[3]);
      // only the change made meanwhile is left to send
      expect(NoteLibrary.unsentChanges.keys, ['/a']);
    });

    test('favorites', () {
      expect(NoteLibrary.isFavorite('/a'), isFalse);
      NoteLibrary.setFavorite('/a.sbn2', true);
      NoteLibrary.setFavorite('/folder/b', true);
      expect(NoteLibrary.isFavorite('/a'), isTrue);
      expect(NoteLibrary.isFavorite('/a.sbn2'), isTrue);
      expect(stows.favoriteNotes.value, ['/folder/b', '/a']);

      // adding it twice doesn't list it twice
      NoteLibrary.setFavorite('/a', true);
      expect(stows.favoriteNotes.value, hasLength(2));

      NoteLibrary.setFavorite('/a', false);
      expect(stows.favoriteNotes.value, ['/folder/b']);
    });

    test('covers', () {
      final color = NoteLibrary.coverColors[3];
      expect(NoteLibrary.coverOf('/a'), isNull);
      NoteLibrary.setCover('/a', color);
      expect(NoteLibrary.coverOf('/a.sbn2'), color);

      NoteLibrary.setCover('/a', null);
      expect(NoteLibrary.coverOf('/a'), isNull);
      expect(stows.noteCovers.value, '{}');
    });

    test('follow a note that is renamed, and forget one that is deleted', () {
      final color = NoteLibrary.coverColors.first;
      NoteLibrary.setFavorite('/a', true);
      NoteLibrary.setFavorite('/other', true);
      NoteLibrary.setCover('/a', color);

      NoteLibrary.noteRenamed('/a.sbn2', '/folder/b.sbn2');
      expect(stows.favoriteNotes.value, ['/other', '/folder/b']);
      expect(NoteLibrary.coverOf('/a'), isNull);
      expect(NoteLibrary.coverOf('/folder/b'), color);

      NoteLibrary.noteRemoved('/folder/b.sbn2');
      expect(stows.favoriteNotes.value, ['/other']);
      expect(NoteLibrary.coverOf('/folder/b'), isNull);
    });
  });

  group('Library pages', () {
    setUp(() async {
      await FileManager.init(shouldWatchRootDirectory: false);
      stows.homeLayout.value = .notebooks;
    });

    Widget app(Widget home) => TranslationProvider(
      child: ScreenshotApp.withConditionalTitlebar(
        device: GoldenSmallDevices.androidPhone.device,
        title: 'Note+',
        theme: SaberTheme.createThemeFromSeed(Colors.blue, .light, .android),
        home: home,
      ),
    );

    testWidgets('a notebook shows its name, cover and favorite star', (
      tester,
    ) async {
      NoteLibrary.setFavorite('/Maths', true);
      NoteLibrary.setCover('/Maths', NoteLibrary.coverColors[1]);
      BrowsePage.overrideChildren = DirectoryChildren(const [], const [
        'Maths',
        'History',
      ]);
      addTearDown(() => BrowsePage.overrideChildren = null);

      await tester.pumpWidget(app(const BrowsePage()));
      await tester.pumpAndSettle();

      expect(find.byType(PreviewCard), findsNWidgets(2));
      final covers = tester.widgetList<NotebookCover>(
        find.byType(NotebookCover),
      );
      expect(
        covers.map((cover) => (cover.title, cover.color, cover.favorite)),
        [('Maths', NoteLibrary.coverColors[1], true), ('History', null, false)],
      );
      // on the cover's label and under the notebook
      expect(find.text('Maths'), findsNWidgets(2));
      expect(find.text('History'), findsOneWidget);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });

    testWidgets('searching filters the notes by name', (tester) async {
      BrowsePage.overrideChildren = DirectoryChildren(
        const ['folder'],
        const ['Maths chapter 1', 'Maths chapter 2', 'History'],
      );
      addTearDown(() => BrowsePage.overrideChildren = null);

      await tester.pumpWidget(app(const BrowsePage()));
      await tester.pumpAndSettle();
      expect(find.byType(PreviewCard), findsNWidgets(3));
      expect(find.text('folder'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'chapter maths');
      await tester.pumpAndSettle();
      expect(find.byType(PreviewCard), findsNWidgets(2));
      expect(find.text('History'), findsNothing);
      expect(find.text('folder'), findsNothing, reason: 'Folders are hidden');

      await tester.enterText(find.byType(TextField), 'geography');
      await tester.pumpAndSettle();
      expect(find.byType(PreviewCard), findsNothing);
      expect(find.text(t.home.noSearchResults), findsOneWidget);

      // leaving the search shows the folder again
      await tester.tap(find.byIcon(Icons.search_off));
      await tester.pumpAndSettle();
      expect(find.byType(PreviewCard), findsNWidgets(3));
      expect(find.text('folder'), findsOneWidget);
    });

    testWidgets('selected notes can be made favorites', (tester) async {
      BrowsePage.overrideChildren = DirectoryChildren(const [], const [
        'Maths',
        'History',
      ]);
      addTearDown(() => BrowsePage.overrideChildren = null);

      await tester.pumpWidget(app(const BrowsePage()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t.home.addToFavorites));
      await tester.pumpAndSettle();
      expect(stows.favoriteNotes.value, ['/History']);
      expect(find.byTooltip(t.home.removeFromFavorites), findsOneWidget);

      await tester.tap(find.byTooltip(t.home.cover.change));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(NotebookCover),
            )
            .at(3),
      );
      await tester.pumpAndSettle();
      expect(NoteLibrary.coverOf('/History'), NoteLibrary.coverColors[2]);
    });
  });
}
