import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/schedule.dart';

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  debugPrint('Background notification response: ${response.payload}');
}

class PermissionStatusSummary {
  final bool notificationGranted;
  final bool exactAlarmGranted;
  final bool batteryOptimizationIgnored;
  final bool systemAlertWindowGranted;
  final bool fullScreenIntentGranted;

  const PermissionStatusSummary({
    required this.notificationGranted,
    required this.exactAlarmGranted,
    required this.batteryOptimizationIgnored,
    required this.systemAlertWindowGranted,
    required this.fullScreenIntentGranted,
  });

  bool get allBasicGranted =>
      notificationGranted && exactAlarmGranted && batteryOptimizationIgnored;

  bool get allGranted =>
      notificationGranted &&
      exactAlarmGranted &&
      batteryOptimizationIgnored &&
      systemAlertWindowGranted &&
      fullScreenIntentGranted;
}

class NotifService {
  NotifService._();
  static final NotifService instance = NotifService._();

  static const MethodChannel _nativeAlarmChannel =
      MethodChannel('com.mendekarena.mendek_arena_masteran/alarm');

  static const String _channelId = 'mendek_arena_masteran_alarm_v2';
  static const String _channelName = 'Jadwal Masteran Burung';
  static const String _channelDesc =
      'Alarm otomatis untuk membuka pemutar video masteran burung';

  static const String _bmkgChannelId = 'mendek_bmkg_cuaca_esok_v1';
  static const String _bmkgChannelName = 'Prakiraan Cuaca BMKG Esok';
  static const String _bmkgChannelDesc =
      'Info otomatis jam hujan dan jam panas besok dari BMKG sesuai wilayah HP';
  static const int _bmkgInstantNotifId = 991001;
  static const int _bmkgDailyNotifId = 991002;
  static const String _licenseChannelId = 'mendek_license_status_v1';
  static const String _licenseChannelName = 'Status Lisensi Sewa';
  static const String _licenseChannelDesc =
      'Pemberitahuan otomatis ketika masa aktif license habis';
  static const int _licenseExpiredNotifId = 991999;
  static const String _careChannelId = 'mendek_care_ef_reminder_v1';
  static const String _careChannelName = 'Pengingat EF & Rawat Burung';
  static const String _careChannelDesc =
      'Pengingat jam makan EF, embun, mandi, jemur, dan vitamin burung';
  static const int _careTimerNotifId = 992999;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<String> _payloadController =
      StreamController<String>.broadcast();

  Stream<String> get onNotificationPayload => _payloadController.stream;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      final String localTimezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTimezone));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));
    }

    _nativeAlarmChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onAlarmTriggered') {
        final String? payload = call.arguments as String?;
        if (payload != null && payload.isNotEmpty && _payloadController.hasListener) {
          _payloadController.add(payload);
          return true;
        }
        return false;
      }
      return null;
    });

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _payloadController.add(payload);
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      const AndroidNotificationChannel channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(channel);
      const AndroidNotificationChannel bmkgChannel = AndroidNotificationChannel(
        _bmkgChannelId,
        _bmkgChannelName,
        description: _bmkgChannelDesc,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(bmkgChannel);
      const AndroidNotificationChannel licChannel = AndroidNotificationChannel(
        _licenseChannelId,
        _licenseChannelName,
        description: _licenseChannelDesc,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(licChannel);
      const AndroidNotificationChannel careChannel = AndroidNotificationChannel(
        _careChannelId,
        _careChannelName,
        description: _careChannelDesc,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );
      await androidPlugin.createNotificationChannel(careChannel);
    }

    _initialized = true;
  }

  Future<bool> pingNativeAlarmBridge() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? ok = await _nativeAlarmChannel.invokeMethod<bool>('ping');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getLaunchPayload() async {
    await init();

    if (Platform.isAndroid) {
      try {
        final String? nativePayload = await _nativeAlarmChannel
            .invokeMethod<String>('getInitialAlarmPayload');
        if (nativePayload != null && nativePayload.isNotEmpty) {
          return nativePayload;
        }
      } catch (_) {}
    }

    final NotificationAppLaunchDetails? details =
        await _plugin.getNotificationAppLaunchDetails();
    if (details != null &&
        details.didNotificationLaunchApp &&
        details.notificationResponse?.payload != null &&
        details.notificationResponse!.payload!.isNotEmpty) {
      return details.notificationResponse!.payload;
    }
    return null;
  }

  Future<void> clearActiveAlarmNotification() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('clearAlarmNotification');
    } catch (_) {}
  }

  Future<void> startPlaybackForegroundService({
    required String title,
    required String body,
    String payload = '',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('startPlaybackForegroundService', {
        'title': title,
        'body': body,
        'payload': payload,
      });
    } catch (_) {}
  }

  Future<void> stopPlaybackForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('stopPlaybackForegroundService');
    } catch (_) {}
  }

  Future<void> ensureBackgroundFallbackAudio({
    required String title,
    required String body,
    String payload = '',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('ensureBackgroundFallbackAudio', {
        'title': title,
        'body': body,
        'payload': payload,
      });
    } catch (_) {}
  }

  Future<void> startStandbyService({
    required int activeCount,
    String? nextLabel,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('startStandbyService', {
        'title': 'Mendek Arena — Siaga Alarm ($activeCount jadwal)',
        'body': nextLabel ?? 'Tetap berbunyi otomatis meski aplikasi ditutup & layar terkunci',
      });
    } catch (_) {}
  }

  Future<void> stopStandbyService() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('stopStandbyService');
    } catch (_) {}
  }

  Future<bool> _canUseFullScreenIntent() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? allowed = await _nativeAlarmChannel
          .invokeMethod<bool>('canUseFullScreenIntent');
      return allowed ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> openFullScreenIntentSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {}
  }

  Future<void> openAppDetailsSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeAlarmChannel.invokeMethod('openAppDetailsSettings');
    } catch (_) {}
  }

  Future<bool> requestSystemAlertWindowPermission() async {
    if (!Platform.isAndroid) return true;
    var status = await Permission.systemAlertWindow.status;
    if (!status.isGranted) {
      status = await Permission.systemAlertWindow.request();
    }
    return status.isGranted;
  }

  Future<PermissionStatusSummary> requestRequiredPermissions() async {
    await init();

    var notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      notifStatus = await Permission.notification.request();
    }

    var exactAlarmStatus = await Permission.scheduleExactAlarm.status;
    if (!exactAlarmStatus.isGranted) {
      exactAlarmStatus = await Permission.scheduleExactAlarm.request();
    }

    var batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    if (!batteryStatus.isGranted) {
      batteryStatus = await Permission.ignoreBatteryOptimizations.request();
    }

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      await androidPlugin.requestExactAlarmsPermission();
    }

    return checkPermissions();
  }

  Future<PermissionStatusSummary> checkPermissions() async {
    final notif = await Permission.notification.isGranted;
    final exact = await Permission.scheduleExactAlarm.isGranted;
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    final overlay =
        Platform.isAndroid ? await Permission.systemAlertWindow.isGranted : true;
    final fullScreen = await _canUseFullScreenIntent();

    return PermissionStatusSummary(
      notificationGranted: notif,
      exactAlarmGranted: exact,
      batteryOptimizationIgnored: battery,
      systemAlertWindowGranted: overlay,
      fullScreenIntentGranted: fullScreen,
    );
  }

  int _notificationIdFor(String scheduleId, int weekday) {
    int hash = 0;
    for (int i = 0; i < scheduleId.length; i++) {
      hash = (hash * 31 + scheduleId.codeUnitAt(i)) & 0x07FFFFFF;
    }
    return (hash * 10 + weekday) & 0x7FFFFFFF;
  }

  DateTime _nextLocalWeekdayAndTime(
    int weekday,
    int hour,
    int minute,
  ) {
    final DateTime now = DateTime.now();
    DateTime scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    while (scheduled.weekday != weekday || !scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  Future<void> cancelSchedule(String scheduleId) async {
    await init();
    for (int weekday = 1; weekday <= 7; weekday++) {
      final int reqCode = _notificationIdFor(scheduleId, weekday);
      await _plugin.cancel(reqCode);
      if (Platform.isAndroid) {
        try {
          await _nativeAlarmChannel.invokeMethod('cancelAlarm', {
            'requestCode': reqCode,
          });
        } catch (_) {}
      }
    }
  }

  Future<void> scheduleNotificationsFor(Schedule schedule) async {
    await init();
    await cancelSchedule(schedule.id);

    if (!schedule.isActive || schedule.days.isEmpty) {
      return;
    }

    for (final int weekday in schedule.days) {
      if (weekday < 1 || weekday > 7) continue;

      final int reqCode = _notificationIdFor(schedule.id, weekday);
      final DateTime localScheduled = _nextLocalWeekdayAndTime(
        weekday,
        schedule.startHour,
        schedule.startMinute,
      );

      if (Platform.isAndroid) {
        try {
          await _nativeAlarmChannel.invokeMethod('scheduleWeeklyAlarm', {
            'requestCode': reqCode,
            'triggerAtMillis': localScheduled.millisecondsSinceEpoch,
            'weekday': weekday,
            'hour': schedule.startHour,
            'minute': schedule.startMinute,
            'title': 'Masteran Burung: ${schedule.name}',
            'body':
                'Memutar ${schedule.platformLabel} (${schedule.timeRangeText})',
            'payload': '${schedule.payload}|LIVE|${schedule.localFilePath ?? ''}',
          });
          continue;
        } catch (e) {
          debugPrint('Native AlarmClock schedule fallback: $e');
        }
      }

      final tz.TZDateTime scheduledDate = tz.TZDateTime.from(
        localScheduled,
        tz.local,
      );

      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        visibility: NotificationVisibility.public,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        autoCancel: true,
        playSound: true,
        enableVibration: true,
        ticker: 'Waktunya Masteran: ${schedule.name}',
      );

      final NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
      );

      await _plugin.zonedSchedule(
        reqCode,
        'Masteran Burung: ${schedule.name}',
        'Memutar ${schedule.platformLabel} (${schedule.timeRangeText})',
        scheduledDate,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: '${schedule.payload}|LIVE|${schedule.localFilePath ?? ''}',
      );
    }
  }

  Future<void> scheduleTestAlarmInSeconds(
    Schedule schedule, {
    int seconds = 10,
  }) async {
    await init();
    final int reqCode = 880000 + (DateTime.now().millisecondsSinceEpoch % 9999);
    final int triggerMillis =
        DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch;
    final String testPayload = '${schedule.payload}|TEST|${schedule.localFilePath ?? ''}';

    if (Platform.isAndroid) {
      try {
        await _nativeAlarmChannel.invokeMethod('scheduleOneShotAlarm', {
          'requestCode': reqCode,
          'triggerAtMillis': triggerMillis,
          'title': 'Tes Alarm: ${schedule.name}',
          'body': 'Membuka pemutar ${schedule.platformLabel} otomatis...',
          'payload': testPayload,
        });
        return;
      } catch (e) {
        debugPrint('Native test alarm fallback: $e');
      }
    }

    final tz.TZDateTime scheduledDate =
        tz.TZDateTime.now(tz.local).add(Duration(seconds: seconds));

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
      autoCancel: true,
    );

    await _plugin.zonedSchedule(
      reqCode,
      'Tes Alarm: ${schedule.name}',
      'Membuka pemutar ${schedule.platformLabel} otomatis...',
      scheduledDate,
      const NotificationDetails(android: androidDetails),
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: testPayload,
    );
  }

  Future<void> rescheduleAll(List<Schedule> schedules) async {
    await init();
    await _plugin.cancelAll();
    if (Platform.isAndroid) {
      try {
        await _nativeAlarmChannel.invokeMethod('cancelAllAlarms');
      } catch (_) {}
    }
    for (final schedule in schedules) {
      if (schedule.isActive) {
        await scheduleNotificationsFor(schedule);
      }
    }
  }

  Future<void> showBmkgTomorrowNotification({
    required String title,
    required String summaryBody,
    required String bigBody,
  }) async {
    await init();
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _bmkgChannelId,
      _bmkgChannelName,
      channelDescription: _bmkgChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(
        bigBody,
        contentTitle: title,
        summaryText: 'Prakiraan BMKG Besok',
      ),
      playSound: true,
      enableVibration: true,
    );
    await _plugin.show(
      _bmkgInstantNotifId,
      title,
      summaryBody,
      NotificationDetails(android: androidDetails),
      payload: 'bmkg_cuaca',
    );
  }

  Future<void> scheduleDailyBmkgReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    await init();
    await _plugin.cancel(_bmkgDailyNotifId);

    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      _bmkgChannelId,
      _bmkgChannelName,
      channelDescription: _bmkgChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'Prakiraan BMKG Besok',
      ),
      playSound: true,
      enableVibration: true,
    );

    try {
      await _plugin.zonedSchedule(
        _bmkgDailyNotifId,
        title,
        body,
        scheduled,
        NotificationDetails(android: androidDetails),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'bmkg_cuaca',
      );
    } catch (_) {
      await _plugin.zonedSchedule(
        _bmkgDailyNotifId,
        title,
        body,
        scheduled,
        NotificationDetails(android: androidDetails),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'bmkg_cuaca',
      );
    }
  }

  Future<void> cancelBmkgReminder() async {
    await init();
    await _plugin.cancel(_bmkgDailyNotifId);
  }

  void dispose() {
    _payloadController.close();
  }

  Future<void> showLicenseExpiredNotification([
    String message = 'License expired, silakan meminta yang baru.',
  ]) async {
    await init();
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _licenseChannelId,
      _licenseChannelName,
      channelDescription: _licenseChannelDesc,
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.status,
      visibility: NotificationVisibility.public,
      playSound: true,
      enableVibration: true,
    );
    await _plugin.show(
      _licenseExpiredNotifId,
      'License Expired — Mendek Arena',
      message,
      const NotificationDetails(android: androidDetails),
      payload: 'license_expired',
    );
  }

  Future<void> showCareTimerFinishedNotification(String title) async {
    await init();
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _careChannelId,
      _careChannelName,
      channelDescription: _careChannelDesc,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    await _plugin.show(
      _careTimerNotifId,
      'Timer Rawatan Selesai',
      'Waktu "$title" sudah selesai. Segera teduhkan / lanjutkan rawatan.',
      const NotificationDetails(android: androidDetails),
      payload: 'care_timer_done',
    );
  }

  Future<void> syncCareDailyReminders(
    List<Map<String, dynamic>> careItems,
  ) async {
    await init();
    for (int id = 992000; id < 992100; id++) {
      await _plugin.cancel(id);
    }
    int slot = 0;
    for (final item in careItems) {
      if (slot >= 100) break;
      if (item['notify'] == false) continue;
      final rawTime = (item['time']?.toString() ?? '').trim();
      final parts = rawTime.split(':');
      if (parts.length != 2) continue;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        continue;
      }
      final title = (item['title']?.toString() ?? 'Rawatan Burung').trim();
      final detail = (item['detail']?.toString() ?? '').trim();
      final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
      tz.TZDateTime scheduled = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        hour,
        minute,
      );
      if (!scheduled.isAfter(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        _careChannelId,
        _careChannelName,
        channelDescription: _careChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
      );
      try {
        await _plugin.zonedSchedule(
          992000 + slot,
          'Pengingat Rawatan: $title',
          detail.isNotEmpty ? detail : 'Waktunya settingan / EF burung ($rawTime).',
          scheduled,
          const NotificationDetails(android: androidDetails),
          androidScheduleMode: AndroidScheduleMode.alarmClock,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
          payload: 'care_reminder',
        );
      } catch (e) {
        debugPrint('Care reminder schedule error: $e');
      }
      slot++;
    }
  }
}
