import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flashcards/study_state.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/sync/realtime/note_ops.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/study.dart';

/// Returns a note with [cards] pages that have something drawn on them,
/// followed by a blank page.
EditorCoreInfo _deck(int cards) {
  final coreInfo = EditorCoreInfo(filePath: '/deck')..flashcards = true;
  for (int i = 0; i <= cards; ++i) {
    final page = EditorPage();
    coreInfo.pages.add(page);
    if (i == cards) break;
    page.insertStroke(
      Stroke(
          color: Colors.black,
          pressureEnabled: true,
          options: StrokeOptions(),
          pageIndex: i,
          page: page,
          toolId: .fountainPen,
        )
        ..addPoint(const Offset(10, 10), 0.5)
        ..addPoint(const Offset(60, 40), 0.5),
    );
  }
  coreInfo.assignPageIds();
  return coreInfo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final now = DateTime.utc(2026, 10, 2, 12);

  group('StudyState', () {
    test('a new card is due, and comes back later the better it is known', () {
      final unseen = StudyState.unseen;
      expect(unseen.isDue(now), isTrue);

      final again = unseen.graded(.again, now);
      expect(again.due, now.add(const Duration(minutes: 10)));
      expect(again.repetitions, 0);
      expect(again.lapses, 1);
      expect(again.isDue(now), isFalse);
      expect(again.isDue(now.add(const Duration(minutes: 10))), isTrue);

      expect(unseen.graded(.hard, now).due, now.add(const Duration(days: 1)));
      expect(unseen.graded(.good, now).due, now.add(const Duration(days: 1)));
      expect(unseen.graded(.easy, now).due, now.add(const Duration(days: 4)));
    });

    test('the interval grows each time the card is remembered', () {
      var state = StudyState.unseen;
      final intervals = <double>[];
      var time = now;
      for (int i = 0; i < 5; ++i) {
        state = state.graded(.good, time);
        intervals.add(state.intervalDays);
        time = state.due;
      }
      expect(intervals.take(2), [1, 3]);
      expect(intervals[2], closeTo(7.5, 0.01));
      for (int i = 1; i < intervals.length; ++i) {
        expect(intervals[i], greaterThan(intervals[i - 1]));
      }
      expect(state.repetitions, 5);
    });

    test('forgetting a card starts over and makes it grow more slowly', () {
      final known = StudyState.unseen
          .graded(.good, now)
          .graded(.good, now)
          .graded(.good, now);
      final forgotten = known.graded(.again, now);
      expect(forgotten.repetitions, 0);
      expect(forgotten.ease, lessThan(known.ease));
      expect(forgotten.graded(.good, now).intervalDays, 1);

      // the ease never drops so low that the card stops progressing
      var state = known;
      for (int i = 0; i < 20; ++i) {
        state = state.graded(.again, now);
      }
      expect(state.ease, StudyState.minEase);
    });

    test('is saved with the note', () {
      final state = StudyState.unseen.graded(.good, now).graded(.easy, now);
      expect(StudyState.fromJson(state.toJson()), state);
    });
  });

  group('Notes', () {
    test('keep their flashcards when saved', () async {
      final deck = _deck(2);
      deck.pages[1].study = StudyState.unseen.graded(.good, now);

      final (bson, _) = deck.saveToBinary(currentPageIndex: null);
      final loaded = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: bson,
        path: '/deck',
        onlyFirstPage: false,
      );
      expect(loaded.flashcards, isTrue);
      expect(loaded.pages[0].study, isNull);
      expect(loaded.pages[1].study, deck.pages[1].study);
    });

    test('share their flashcards with the other devices', () {
      final deck = _deck(2);
      deck.pages[0].study = StudyState.unseen.graded(.easy, now);

      final other = EditorCoreInfo(filePath: '/deck')
        ..pages.add(EditorPage())
        ..assignPageIds();
      final applier = NoteOpApplier(
        coreInfo: other,
        createPage: (pageIndex) {
          while (pageIndex >= other.pages.length - 1) {
            other.pages.add(EditorPage());
            other.assignPageIds();
          }
        },
        removeExcessPages: () {},
      );
      NoteOps.snapshot(deck).forEach(applier.apply);
      expect(other.flashcards, isTrue);
      expect(other.pages[0].study, deck.pages[0].study);
      expect(other.pages[1].study, isNull);

      // studying a card on one device updates it on the other
      deck.pages[1].study = StudyState.unseen.graded(.again, now);
      applier.apply(NoteOps.study(deck.pages[1]));
      expect(other.pages[1].study, deck.pages[1].study);

      // unless it was studied here at the same time
      final local = NoteOps.study(other.pages[1]);
      deck.pages[1].study = deck.pages[1].study!.graded(.easy, now);
      applier.apply(NoteOps.study(deck.pages[1]), pendingLocalOps: [local]);
      expect(other.pages[1].study!.repetitions, 0);

      deck.flashcards = false;
      applier.apply(NoteOps.flashcards(deck));
      expect(other.flashcards, isFalse);
    });
  });

  group('StudyPage', () {
    Future<List<EditorPage>> pump(
      WidgetTester tester,
      EditorCoreInfo deck,
    ) async {
      final graded = <EditorPage>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StudyPage(
              coreInfo: deck,
              onGraded: graded.add,
              now: () => now,
            ),
          ),
        ),
      );
      return graded;
    }

    testWidgets('shows each due card, question first', (tester) async {
      final deck = _deck(3);
      // the second card isn't due yet
      deck.pages[1].study = StudyState.unseen.graded(.good, now);
      final graded = await pump(tester, deck);

      expect(find.text('0 / 2'), findsOneWidget);
      expect(find.text(t.editor.flashcards.showAnswer), findsOneWidget);
      expect(find.text(t.editor.flashcards.good), findsNothing);

      await tester.tap(find.text(t.editor.flashcards.showAnswer));
      await tester.pump();
      expect(find.text(t.editor.flashcards.showAnswer), findsNothing);
      for (final label in [
        t.editor.flashcards.again,
        t.editor.flashcards.hard,
        t.editor.flashcards.good,
        t.editor.flashcards.easy,
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // when each answer brings the card back
      expect(find.text('10 min'), findsOneWidget);
      expect(find.text('1 d'), findsNWidgets(2));
      expect(find.text('4 d'), findsOneWidget);

      await tester.tap(find.text(t.editor.flashcards.easy));
      await tester.pump();
      expect(graded, [deck.pages[0]]);
      expect(deck.pages[0].study!.due, now.add(const Duration(days: 4)));
      expect(find.text('1 / 2'), findsOneWidget);

      // a card that wasn't remembered comes back at the end
      await tester.tap(find.text(t.editor.flashcards.showAnswer));
      await tester.pump();
      await tester.tap(find.text(t.editor.flashcards.again));
      await tester.pump();
      expect(graded, [deck.pages[0], deck.pages[2]]);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.text(t.editor.flashcards.showAnswer));
      await tester.pump();
      await tester.tap(find.text(t.editor.flashcards.good));
      await tester.pump();

      expect(find.text(t.editor.flashcards.done), findsOneWidget);
      expect(
        find.text(t.editor.flashcards.doneDescription(n: 2)),
        findsOneWidget,
      );
      expect(deck.pages[2].study!.lapses, 1);
    });

    testWidgets('offers to study everything when nothing is due', (
      tester,
    ) async {
      final deck = _deck(2);
      for (final page in deck.pages.take(2)) {
        page.study = StudyState.unseen.graded(.good, now);
      }
      await pump(tester, deck);
      expect(find.text(t.editor.flashcards.nothingDue), findsOneWidget);

      await tester.tap(find.text(t.editor.flashcards.studyAll));
      await tester.pump();
      expect(find.text('0 / 2'), findsOneWidget);
      expect(find.text(t.editor.flashcards.showAnswer), findsOneWidget);
    });

    testWidgets('explains what to do when the note has no cards', (
      tester,
    ) async {
      await pump(tester, _deck(0));
      expect(find.text(t.editor.flashcards.noCards), findsOneWidget);
      expect(find.text(t.editor.flashcards.studyAll), findsNothing);
    });
  });
}
