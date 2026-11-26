import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 每日复习提醒（本地通知，不联网）。
///
/// - Android：用非精确闹钟，不需要「闹钟和提醒」特殊权限（和以前完全一样）。
/// - macOS：系统按时发通知，关掉应用也会提醒。
/// - Windows / Linux：系统不支持让已关闭的应用定时通知，所以只在应用开着时到点提醒。
class Reminder {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const _id = 1001;
  static Timer? _timer;
  static String _firedDay = '';

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _mac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  static bool get _inApp =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);

  /// 这台设备上提醒能不能在应用关闭后照常送达。
  static bool get worksWhenClosed => _android || _mac;

  /// 这台设备支不支持提醒。
  static bool get supported => _android || _mac || _inApp;

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
        settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_notify'),
      macOS: DarwinInitializationSettings(
          requestAlertPermission: false, requestSoundPermission: false, requestBadgePermission: false),
      linux: LinuxInitializationSettings(defaultActionName: '打开闪卡刷题'),
      windows: WindowsInitializationSettings(
          appName: '闪卡刷题',
          appUserModelId: 'io.github.henryham88.aiflashcards',
          guid: '6d1f6f0e-3c63-4f5e-9a4b-2b7f6a9c1e52'),
    ));
    _ready = true;
  }

  /// 申请通知权限（Android 13+ / macOS）。返回是否允许。
  static Future<bool> requestPermission() async {
    if (!supported) return false;
    await _init();
    if (_android) {
      final a = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      return await a?.requestNotificationsPermission() ?? true;
    }
    if (_mac) {
      final m = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      return await m?.requestPermissions(alert: true, sound: true) ?? false;
    }
    return true;
  }

  /// 按设置安排（或取消）每天的提醒。
  static Future<void> schedule({required bool on, required int minutes}) async {
    if (!supported) return;
    await _init();
    if (_inApp) {
      _timer?.cancel();
      _timer = null;
      if (!on) return;
      void tick() => _checkInApp(minutes, DateTime.now());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => tick());
      return;
    }
    await _plugin.cancel(id: _id);
    if (!on) return;
    final now = tz.TZDateTime.now(tz.local);
    var at = tz.TZDateTime(tz.local, now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: _id,
      scheduledDate: at,
      title: '该复习啦',
      body: '今天的新卡和到期复习在等你，花几分钟巩固一下吧',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('daily_review', '每日复习提醒',
            channelDescription: '每天固定时间提醒你复习到期的闪卡', importance: Importance.defaultImportance),
        macOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  /// 应用开着时：到了提醒时间（之后两小时内）且今天还没提醒过，就发一条通知。
  @visibleForTesting
  static bool dueInApp(int minutes, DateTime now, String firedDay) {
    final day = '${now.year}-${now.month}-${now.day}';
    if (firedDay == day) return false;
    final at = DateTime(now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    return !now.isBefore(at) && now.difference(at) < const Duration(hours: 2);
  }

  static Future<void> _checkInApp(int minutes, DateTime now) async {
    if (!dueInApp(minutes, now, _firedDay)) return;
    _firedDay = '${now.year}-${now.month}-${now.day}';
    try {
      await _plugin.show(
        id: _id,
        title: '该复习啦',
        body: '今天的新卡和到期复习在等你，花几分钟巩固一下吧',
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
