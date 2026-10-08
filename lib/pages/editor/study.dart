import 'package:flutter/material.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flashcards/study_state.dart';
import 'package:saber/i18n/strings.g.dart';

/// Shows the pages of a note one at a time as flashcards: first the question
/// (the top half of the page), then the answer (the whole page), which the
/// user grades to decide when the card comes back.
class StudyPage extends StatefulWidget {
  const new({
    super.key,
    required this.coreInfo,
    required this.onGraded,
    this.now = DateTime.now,
  });

  final EditorCoreInfo coreInfo;

  /// Called after the [EditorPage.study] of a page has changed.
  final void Function(EditorPage page) onGraded;

  @visibleForTesting
  final DateTime Function() now;

  /// Describes [interval] in a few characters, e.g. "10 min" or "3 d".
  static String describeInterval(Duration interval) {
    if (interval.inHours < 24) {
      return t.editor.flashcards.minutes(n: interval.inMinutes);
    }
    final days = interval.inHours / 24;
    if (days < 30) return t.editor.flashcards.days(n: days.round());
    if (days < 365) return t.editor.flashcards.months(n: (days / 30).round());
    return t.editor.flashcards.years(n: (days / 365).round());
  }

  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  /// The cards left to study in this session, starting with the current one.
  late final List<EditorPage> queue = _dueCards();

  /// How many cards this session started with.
  late int total = queue.length;

  /// How many cards have been remembered in this session.
  var studied = 0;

  /// Whether the answer of the current card is shown.
  var revealed = false;

  /// The pages that have something written on them.
  List<EditorPage> get cards => [
    for (final page in widget.coreInfo.pages)
      if (page.isNotEmpty) page,
  ];

  List<EditorPage> _dueCards() {
    final now = widget.now();
    return [
      for (final page in cards)
        if ((page.study ?? StudyState.unseen).isDue(now)) page,
    ];
  }

  void _studyAll() => setState(() {
    queue
      ..clear()
      ..addAll(cards);
    total = queue.length;
    studied = 0;
    revealed = false;
  });

  void _grade(StudyGrade grade) {
    final page = queue.removeAt(0);
    page.study = (page.study ?? StudyState.unseen).graded(grade, widget.now());
    widget.onGraded(page);
    setState(() {
      if (grade == .again) {
        // show it again once the other cards have been seen
        queue.add(page);
      } else {
        studied++;
      }
      revealed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);

    final Widget body;
    if (queue.isEmpty) {
      final hasCards = cards.isNotEmpty;
      body = Center(
        child: Padding(
          padding: const .all(24),
          child: Column(
            mainAxisSize: .min,
            children: [
              Icon(
                studied > 0 ? Icons.celebration : Icons.style,
                size: 56,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                !hasCards
                    ? t.editor.flashcards.noCards
                    : studied > 0
                    ? t.editor.flashcards.done
                    : t.editor.flashcards.nothingDue,
                textAlign: .center,
                style: textTheme.titleLarge,
              ),
              if (studied > 0) ...[
                const SizedBox(height: 8),
                Text(t.editor.flashcards.doneDescription(n: studied)),
              ],
              const SizedBox(height: 24),
              if (hasCards)
                FilledButton.tonal(
                  onPressed: _studyAll,
                  child: Text(t.editor.flashcards.studyAll),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.editor.flashcards.close),
              ),
            ],
          ),
        ),
      );
    } else {
      final page = queue.first;
      final state = page.study ?? StudyState.unseen;
      body = Column(
        children: [
          LinearProgressIndicator(value: total == 0 ? 0 : studied / total),
          Expanded(
            child: Padding(
              padding: const .all(16),
              child: _Card(
                // a new card isn't animated from the previous one
                key: ValueKey((page.id, revealed)),
                coreInfo: widget.coreInfo,
                page: page,
                revealed: revealed,
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const .fromLTRB(16, 0, 16, 16),
              child: revealed
                  ? Row(
                      spacing: 8,
                      children: [
                        for (final grade in StudyGrade.values)
                          Expanded(
                            child: _GradeButton(
                              grade: grade,
                              interval: state.nextInterval(grade),
                              onPressed: () => _grade(grade),
                            ),
                          ),
                      ],
                    )
                  : SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => setState(() => revealed = true),
                        child: Padding(
                          padding: const .symmetric(vertical: 12),
                          child: Text(t.editor.flashcards.showAnswer),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight,
        title: Text(t.editor.flashcards.study),
        actions: [
          if (queue.isNotEmpty)
            Center(
              child: Padding(
                padding: const .symmetric(horizontal: 16),
                child: Text(
                  t.editor.flashcards.progress(done: studied, total: total),
                  style: textTheme.titleMedium,
                ),
              ),
            ),
        ],
      ),
      body: body,
    );
  }
}

/// A page shown as a flashcard: only its top half until it's [revealed].
class _Card extends StatelessWidget {
  const new({
    super.key,
    required this.coreInfo,
    required this.page,
    required this.revealed,
  });

  final EditorCoreInfo coreInfo;
  final EditorPage page;
  final bool revealed;

  /// Shows the top half of the page, or its bottom half if [answer] is true.
  Widget _half({required bool answer}) {
    final size = page.size;
    return Material(
      elevation: 3,
      borderRadius: .circular(12),
      clipBehavior: .antiAlias,
      child: SizedBox(
        width: size.width,
        height: size.height / 2,
        child: OverflowBox(
          alignment: answer ? .bottomCenter : .topCenter,
          minHeight: size.height,
          maxHeight: size.height,
          // the card is for looking at, not for editing
          child: IgnorePointer(
            child: CanvasPreview(
              pageIndex: coreInfo.pages.indexOf(page),
              height: null,
              coreInfo: coreInfo,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The question and the answer are side by side if that's
        // how they're biggest, otherwise one above the other.
        final halfAspectRatio = page.size.width / (page.size.height / 2);
        final available = constraints.maxWidth / constraints.maxHeight;
        final sideBySide = available > halfAspectRatio;
        return Center(
          child: FittedBox(
            child: Padding(
              padding: const .all(8),
              child: Flex(
                direction: sideBySide ? .horizontal : .vertical,
                spacing: 24,
                mainAxisSize: .min,
                children: [
                  _half(answer: false),
                  if (revealed) _half(answer: true),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GradeButton extends StatelessWidget {
  const new({
    required this.grade,
    required this.interval,
    required this.onPressed,
  });

  final StudyGrade grade;
  final Duration interval;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final color = switch (grade) {
      .again => colorScheme.error,
      .hard => Colors.orange.shade800,
      .good => Colors.green.shade700,
      .easy => colorScheme.primary,
    };
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color),
        padding: const .symmetric(vertical: 8, horizontal: 4),
      ),
      onPressed: onPressed,
      child: Column(
        mainAxisSize: .min,
        children: [
          Text(
            switch (grade) {
              .again => t.editor.flashcards.again,
              .hard => t.editor.flashcards.hard,
              .good => t.editor.flashcards.good,
              .easy => t.editor.flashcards.easy,
            },
            maxLines: 1,
            overflow: .ellipsis,
          ),
          Text(
            StudyPage.describeInterval(interval),
            style: TextTheme.of(context).labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
