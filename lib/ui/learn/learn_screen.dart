import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../curriculum/models.dart';
import '../../progress/progress_store.dart';
import '../lesson/lesson_screen.dart';
import '../practice/practice_hub.dart';
import '../practice/today_card.dart';
import '../theme.dart';
import '../video/lesson_video_player.dart';
import '../widgets/brand_mark.dart';

class LearnScreen extends StatelessWidget {
  const LearnScreen({super.key});

  void _open(BuildContext context, Lesson lesson) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LessonScreen(lesson: lesson)));

  @override
  Widget build(BuildContext context) {
    final curriculum = context.read<AppServices>().curriculum;
    final progress = context.watch<ProgressStore>();
    final next = progress.nextLesson(curriculum);
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            const BrandMark(size: 34),
            const SizedBox(width: 10),
            const Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('Guitaro', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
              ),
            ),
            _Pill(icon: Icons.local_fire_department_rounded, text: '${progress.streak()}'),
            const SizedBox(width: 8),
            _Pill(icon: Icons.bolt_rounded, text: '${progress.xp} XP'),
          ]),
        ),
      ),
      if (next != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: _ContinueCard(lesson: next, level: curriculum.levelOf(next), onTap: () => _open(context, next)),
          ),
        ),
      const SliverToBoxAdapter(child: TodayCard()),
      const SliverToBoxAdapter(child: PracticeTools()),
      for (final level in curriculum.levels) ...[
        SliverToBoxAdapter(child: _LevelHeader(level: level, progress: progress)),
        SliverList.builder(
          itemCount: level.lessons.length,
          itemBuilder: (context, i) {
            final lesson = level.lessons[i];
            final unlocked = progress.isUnlocked(curriculum, lesson);
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: _LessonTile(
                lesson: lesson,
                stars: progress.starsFor(lesson.id),
                complete: progress.isComplete(lesson.id),
                unlocked: unlocked,
                isNext: lesson == next,
                onTap: unlocked ? () => _open(context, lesson) : null,
              ),
            );
          },
        ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: kSurfaceHigh, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          Icon(icon, size: 18, color: kAccent),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.lesson, required this.level, required this.onTap});

  final Lesson lesson;
  final Level level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [kAccent, kAccentSoft]),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('UP NEXT · ${level.title.toUpperCase()}',
                      style: const TextStyle(color: Color(0xCCFFFFFF), fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  Text(lesson.title,
                      style: const TextStyle(color: kOnAccent, fontSize: 24, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(lesson.summary, style: const TextStyle(color: Color(0xDDFFFFFF))),
                ]),
              ),
              const CircleAvatar(
                radius: 28,
                backgroundColor: kOnAccent,
                child: Icon(Icons.play_arrow_rounded, color: kAccent, size: 34),
              ),
            ]),
          ),
        ),
      );
}

class _LevelHeader extends StatelessWidget {
  const _LevelHeader({required this.level, required this.progress});

  final Level level;
  final ProgressStore progress;

  @override
  Widget build(BuildContext context) {
    final done = level.lessons.where((l) => progress.isComplete(l.id)).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
          child: Icon(levelIcon(level.icon), color: kAccent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(level.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text(level.subtitle, style: const TextStyle(color: kMuted)),
          ]),
        ),
        if (context.read<AppServices>().videos.introFor(level.id) case final intro?)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: 'Watch the ${level.title} intro',
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoScreen(video: intro))),
                icon: const Icon(Icons.play_circle_fill_rounded, size: 20),
                label: const Text('Intro'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 34),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ),
        Text('$done/${level.lessons.length}', style: const TextStyle(color: kMuted, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _LessonTile extends StatelessWidget {
  const _LessonTile({
    required this.lesson,
    required this.stars,
    required this.complete,
    required this.unlocked,
    required this.isNext,
    required this.onTap,
  });

  final Lesson lesson;
  final int stars;
  final bool complete, unlocked, isNext;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: unlocked ? 1 : 0.45,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isNext ? kAccent : Colors.transparent, width: 1.5),
        ),
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: CircleAvatar(
            backgroundColor: complete ? kSuccess.withValues(alpha: 0.18) : kSurfaceHigh,
            child: Icon(
              complete ? Icons.check_rounded : (unlocked ? Icons.play_arrow_rounded : Icons.lock_rounded),
              color: complete ? kSuccess : (unlocked ? kAccent : kMuted),
            ),
          ),
          title: Text(lesson.title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(lesson.summary, style: const TextStyle(color: kMuted)),
          trailing: complete
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 3; i++)
                    Icon(i < stars ? Icons.star_rounded : Icons.star_outline_rounded, size: 18, color: kAccent),
                ])
              : null,
        ),
      ),
    );
  }
}
