/// Where a learner starts from.
enum Experience {
  newcomer('Never played', 'Start from the very first lesson'),
  some('I know a few chords', 'Jump to any lesson you like'),
  plays('I already play songs', 'Everything open: practise what you need');

  const Experience(this.label, this.detail);

  final String label, detail;
}

/// What a learner wants to play.
enum Aim {
  songs('Strum and sing songs'),
  melodies('Play melodies'),
  fingerpicking('Fingerpicking'),
  lead('Lead and solos'),
  blues('Blues');

  const Aim(this.label);

  final String label;
}

/// What a learner set out to do, asked when they first open the app (and changed in Me): it
/// opens the course up to where they are, and sizes their daily practice.
class LearningGoal {
  const LearningGoal({this.experience = Experience.newcomer, this.aims = const {Aim.songs}, this.minutes = 15});

  final Experience experience;
  final Set<Aim> aims;

  /// Practice a day, in minutes.
  final int minutes;

  static const dailyMinutes = [5, 10, 15, 30];

  Map<String, Object> toJson() => {
        'experience': experience.name,
        'aims': [for (final a in aims) a.name],
        'minutes': minutes,
      };

  static LearningGoal fromJson(Map<String, dynamic> j) => LearningGoal(
        experience: Experience.values.asNameMap()[j['experience']] ?? Experience.newcomer,
        aims: {for (final a in j['aims'] as List? ?? const []) ?Aim.values.asNameMap()[a]},
        minutes: (j['minutes'] as num?)?.toInt() ?? 15,
      );
}
