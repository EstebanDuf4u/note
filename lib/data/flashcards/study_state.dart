/// How well the user remembered a flashcard.
enum StudyGrade {
  /// Didn't remember: the card comes back later in the same session.
  again,
  hard,
  good,
  easy,
}

/// What the app remembers about how well the user knows a flashcard,
/// to decide when to show it again (spaced repetition).
///
/// A flashcard is a page of a note whose flashcards mode is on:
/// the top half of the page is the question, the bottom half the answer.
class StudyState {
  const new({
    required this.due,
    required this.intervalDays,
    this.ease = initialEase,
    this.repetitions = 0,
    this.lapses = 0,
  });

  /// A card that hasn't been studied yet, which is due right away.
  static final unseen = StudyState(
    due: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    intervalDays: 0,
  );

  static const initialEase = 2.5;
  static const minEase = 1.3;

  /// How long until a card that wasn't remembered is shown again.
  static const againDelay = Duration(minutes: 10);

  /// When the card should be shown again.
  final DateTime due;

  /// How many days there were between the last two times it was shown.
  final double intervalDays;

  /// How fast [intervalDays] grows each time the card is remembered.
  final double ease;

  /// How many times in a row the card has been remembered.
  final int repetitions;

  /// How many times the card has been forgotten.
  final int lapses;

  bool isDue(DateTime now) => !due.isAfter(now);

  /// Returns the interval that grading the card with [grade] would give it.
  Duration nextInterval(StudyGrade grade) {
    final double days;
    switch (grade) {
      case .again:
        return againDelay;
      case .hard:
        days = repetitions == 0 ? 1 : intervalDays * 1.2;
      case .good:
        days = switch (repetitions) {
          0 => 1,
          1 => 3,
          _ => intervalDays * ease,
        };
      case .easy:
        days = repetitions == 0 ? 4 : intervalDays * ease * 1.3;
    }
    return Duration(minutes: (days.clamp(1, 3650) * 24 * 60).round());
  }

  /// Returns the state of the card after the user graded it at [now].
  StudyState graded(StudyGrade grade, DateTime now) {
    final interval = nextInterval(grade);
    return StudyState(
      due: now.add(interval),
      intervalDays: grade == .again ? 0 : interval.inMinutes / (24 * 60),
      ease: switch (grade) {
        .again => ease - 0.2,
        .hard => ease - 0.15,
        .good => ease,
        .easy => ease + 0.15,
      }.clamp(minEase, 4.0),
      repetitions: grade == .again ? 0 : repetitions + 1,
      lapses: grade == .again ? lapses + 1 : lapses,
    );
  }

  factory fromJson(Map<dynamic, dynamic> json) => StudyState(
    due: DateTime.fromMillisecondsSinceEpoch(
      (json['d'] as num).toInt(),
      isUtc: true,
    ),
    intervalDays: (json['i'] as num).toDouble(),
    ease: (json['e'] as num?)?.toDouble() ?? initialEase,
    repetitions: (json['r'] as num?)?.toInt() ?? 0,
    lapses: (json['l'] as num?)?.toInt() ?? 0,
  );

  /// The due date is stored as a double because
  /// it's too large for the 32 bit integers of bson.
  Map<String, dynamic> toJson() => {
    'd': due.millisecondsSinceEpoch.toDouble(),
    'i': intervalDays,
    'e': ease,
    'r': repetitions,
    'l': lapses,
  };

  @override
  bool operator ==(Object other) =>
      other is StudyState &&
      other.due == due &&
      other.intervalDays == intervalDays &&
      other.ease == ease &&
      other.repetitions == repetitions &&
      other.lapses == lapses;

  @override
  int get hashCode => Object.hash(due, intervalDays, ease, repetitions, lapses);

  @override
  String toString() =>
      'StudyState(due: $due, interval: $intervalDays days, ease: $ease, '
      'repetitions: $repetitions, lapses: $lapses)';
}
