import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

/// A daily nudge to practise: a notification the phone itself schedules, so nothing leaves it.
class Reminders {
  Reminders([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  static const _id = 1;

  Future<void> _init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Asked for when the learner turns the reminder on, not at startup.
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
    );
    _ready = true;
  }

  /// Asks to show notifications; false when the learner says no (or they can't be shown).
  Future<bool> askPermission() async {
    try {
      await _init();
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) return await android.requestNotificationsPermission() ?? false;
      final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(alert: true, sound: true) ?? false;
    } catch (e) {
      debugPrint('Reminders: could not ask for permission: $e');
      return false;
    }
  }

  /// Reminds every day at [minutes] past midnight, or not at all when null. A reminder that
  /// can't be set mustn't break anything: it's only a nudge.
  Future<void> set(int? minutes, {DateTime? now}) async {
    try {
      await _init();
      await _plugin.cancel(id: _id);
      if (minutes == null) return;
      await _plugin.zonedSchedule(
        id: _id,
        scheduledDate: nextAt(minutes, now ?? DateTime.now()),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('practice', 'Practice reminders', channelDescription: 'A daily nudge to practise'),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: 'Time to practise',
        body: "Today's plan is ready: about a quarter of an hour.",
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (e) {
      debugPrint('Reminders: could not set the reminder: $e');
    }
  }

  /// The next time it's [minutes] past midnight, local time. Given in UTC, which needs no time
  /// zone database: a daylight-saving change moves it by an hour, until the app next starts and
  /// sets it again.
  static tz.TZDateTime nextAt(int minutes, DateTime now) {
    var at = DateTime(now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    return tz.TZDateTime.from(at, tz.UTC);
  }
}
