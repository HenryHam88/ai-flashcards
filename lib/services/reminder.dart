import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 每日复习提醒（本地通知，不联网）。用非精确闹钟，不需要「闹钟和提醒」特殊权限。
class Reminder {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const _id = 1001;

  static Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // 拿不到时区就用 UTC 偏移最接近的默认值
    }
    await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_notify')));
    _ready = true;
  }

  /// 申请通知权限（Android 13+）。返回是否允许。
  static Future<bool> requestPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    await _init();
    final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    return await a?.requestNotificationsPermission() ?? true;
  }

  /// 按设置安排（或取消）每天的提醒。
  static Future<void> schedule({required bool on, required int minutes}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await _init();
    await _plugin.cancel(id: _id);
    if (!on) return;
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: _id,
      scheduledDate: at,
      title: '该复习啦',
      body: '今天的闪卡在等你，花几分钟巩固一下吧',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('daily_review', '每日复习提醒',
            channelDescription: '每天固定时间提醒你复习到期的闪卡', importance: Importance.defaultImportance),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }
}
