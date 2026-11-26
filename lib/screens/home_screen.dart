import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/schedule.dart';
import '../services/api_service.dart';
import '../services/bmkg_weather_service.dart';
import '../services/db_service.dart';
import '../services/notif_service.dart';
import '../services/offline_service.dart';
import '../services/social_service.dart';
import '../services/url_helper.dart';
import '../widgets/premium_visuals.dart';
import 'add_edit_screen.dart';
import 'live_module_webview_screen.dart';
import 'login_screen.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  final String? initialPayload;

  const HomeScreen({super.key, this.initialPayload});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const String _prefNightStandby = 'mendek_night_standby_v1';
  static const String _prefBirdName = 'mendek_bird_name_v1';
  static const String _prefBirdMode = 'mendek_bird_mode_v1';
  static const String _prefCareItems = 'mendek_care_items_v1';
  static const String _prefBirdProfiles = 'mendek_bird_profiles_v3';
  static const String _prefActiveBirdId = 'mendek_active_bird_id_v3';
  static const String _prefCareByBird = 'mendek_care_by_bird_v3';

  List<BirdProfile> _birdProfiles = const [
    BirdProfile(
      id: 'bird_default',
      name: 'Murai Petir',
      species: 'Murai Batu',
      mode: 'Harian',
    ),
  ];
  String _activeBirdId = 'bird_default';
  Map<String, List<Map<String, dynamic>>> _careItemsByBird = {};
  String _installedAppVersion = ApiService.appVersion;
  BmkgTomorrowSummary? _bmkgSummary;
  bool _bmkgLoading = false;
  bool _bmkgAutoNotif = true;
  List<SocialPost> _socialPosts = const [];
  bool _socialLoading = false;
  bool _socialPosting = false;
  String _socialCategoryFilter = 'all';
  bool _autoShareBmkg = false;

  String _birdName = 'Murai Petir';
  String _birdMode = 'Harian';
  List<Map<String, dynamic>> _careItems = [];

  BirdProfile get _activeBird {
    if (_activeBirdId == 'all') return _birdProfiles.first;
    return _birdProfiles.firstWhere(
      (b) => b.id == _activeBirdId,
      orElse: () => _birdProfiles.first,
    );
  }

  List<Schedule> get _filteredSchedules {
    if (_activeBirdId == 'all') return _schedules;
    return _schedules.where((s) => s.birdId == _activeBirdId).toList();
  }

  List<Schedule> _schedules = [];
  bool _isLoading = true;
  PermissionStatusSummary? _permStatus;
  StreamSubscription<String>? _notifSub;
  Timer? _clockWatcherTimer;
  Timer? _autoSyncTimer;
  int _activeSyncIntervalSec = 90;
  bool _downloadingApkUpdate = false;
  double _apkDownloadProgress = 0.0;
  bool _initialHandled = false;
  bool _isPlayerOpen = false;
  bool _nightStandbyMode = false;
  int _activeTabIndex = 0;

  final Set<String> _triggeredScheduleKeys = {};
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloadingIds = {};
  bool? _nativeBridgeActive;
  DateTime _clockNow = DateTime.now();

  RemoteConfig get _cfg => ApiService.instance.remoteConfig;
  Color get _appleBlue => _cfg.accentColor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notifSub = NotifService.instance.onNotificationPayload.listen((payload) {
      _openPlayerFromPayload(payload, isManualPreview: false);
    });
    _clockWatcherTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        if (!mounted) return;
        setState(() {
          _clockNow = DateTime.now();
        });
        _checkActiveScheduleNow();
      },
    );
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatusOnly();
      unawaited(_checkPendingNativeAlarmPayload());
      _checkActiveScheduleNow();
      if (_nightStandbyMode && !_isPlayerOpen) {
        unawaited(WakelockPlus.enable());
      }
      unawaited(_refreshBmkgForecast());
      unawaited(_syncLiveFromServerAndGithub());
    }
  }

  Future<void> _checkPendingNativeAlarmPayload() async {
    final payload = await NotifService.instance.getLaunchPayload();
    if (!mounted) return;
    if (payload != null && payload.isNotEmpty) {
      _openPlayerFromPayload(payload, isManualPreview: false);
    }
  }

  Future<void> _refreshPermissionStatusOnly() async {
    final perms = await NotifService.instance.checkPermissions();
    final bridgeOk = await NotifService.instance.pingNativeAlarmBridge();
    if (!mounted) return;
    setState(() {
      _permStatus = perms;
      _nativeBridgeActive = bridgeOk;
    });
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final savedStandby = prefs.getBool(_prefNightStandby) ?? false;
    if (savedStandby) {
      await WakelockPlus.enable();
    }

    if (!_initialHandled &&
        widget.initialPayload != null &&
        widget.initialPayload!.isNotEmpty) {
      _initialHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openPlayerFromPayload(widget.initialPayload!, isManualPreview: false);
      });
    }

    final bridgeOk = await NotifService.instance.pingNativeAlarmBridge();
    final installedVer = await ApiService.instance.getInstalledAppVersion();
    await BmkgWeatherService.instance.init();
    await SocialService.instance.init();
    await DbService.instance.seedDefaultSchedulesIfEmpty();
    await _loadCareState();
    final schedules = await _syncLocalOfflinePaths(
      await DbService.instance.getAllSchedules(),
    );
    await NotifService.instance.rescheduleAll(schedules);
    await BmkgWeatherService.instance.ensureReminderScheduled();
    final activeForStandby = schedules.where((s) => s.isActive).toList();
    if (activeForStandby.isNotEmpty) {
      await NotifService.instance.startStandbyService(
        activeCount: activeForStandby.length,
        nextLabel: _nextAlarmCountdownLabel(activeForStandby),
      );
    } else {
      await NotifService.instance.stopStandbyService();
    }

    PermissionStatusSummary perms;
    if (widget.initialPayload == null || widget.initialPayload!.isEmpty) {
      perms = await NotifService.instance.requestRequiredPermissions();
    } else {
      perms = await NotifService.instance.checkPermissions();
    }

    if (!mounted) return;
    setState(() {
      _installedAppVersion = installedVer;
      _bmkgAutoNotif = BmkgWeatherService.instance.autoNotifEnabled;
      _bmkgSummary = BmkgWeatherService.instance.getTomorrowSummary();
      _autoShareBmkg = SocialService.instance.autoShareBmkg;
      _socialPosts = SocialService.instance.cachedPosts;
      _nightStandbyMode = savedStandby;
      _permStatus = perms;
      _nativeBridgeActive = bridgeOk;
      _schedules = schedules;
      _clockNow = DateTime.now();
      _isLoading = false;
    });

    _checkActiveScheduleNow();
    _startOrResetAutoSyncTimer();
    unawaited(_syncLiveFromServerAndGithub(forceReleaseCheck: true));
    unawaited(_refreshSocialFeed());
    unawaited(_autoSetupBmkgOnFirstOpen());
  }

  void _startOrResetAutoSyncTimer() {
    final interval = _cfg.syncIntervalSec.clamp(30, 600);
    if (_autoSyncTimer != null && _activeSyncIntervalSec == interval) {
      return;
    }
    _autoSyncIntervalSec = interval;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(
      Duration(seconds: interval),
      (_) {
        if (!mounted) return;
        unawaited(_syncLiveFromServerAndGithub());
      },
    );
  }

  Future<bool> _syncLiveFromServerAndGithub({bool forceReleaseCheck = false}) async {
    final stillValid = await ApiService.instance.syncAllFromServerAndGithub(
      forceReleaseCheck: forceReleaseCheck,
    );
    if (!mounted) return stillValid;
    if (!stillValid) {
      Navigator.of(context).pushReplacement(
        buildPremiumRoute(LoginScreen(pendingPayload: widget.initialPayload)),
      );
      return false;
    }
    if (_cfg.syncIntervalSec != _activeSyncIntervalSec) {
      _startOrResetAutoSyncTimer();
    }
    setState(() {});
    return true;
  }

  List<Map<String, dynamic>> _defaultCareItems() {
    return [
      {'title': 'Embun Pagi (05:30)', 'detail': 'Gantang teras 30 menit', 'done': false},
      {'title': 'Pakan EF Pagi (07:00)', 'detail': '5 jangkrik + air bersih', 'done': false},
      {'title': 'Mandi Keramba (08:00)', 'detail': 'Mandi pagi secukupnya', 'done': false},
      {'title': 'Jemur Pagi (08:30)', 'detail': 'Jemur 35 menit lalu teduh', 'done': false},
      {'title': 'EF Sore (16:30)', 'detail': '4 jangkrik + kroto', 'done': false},
      {'title': 'Kerodong Malam (18:30)', 'detail': 'Siap masteran malam', 'done': false},
    ];
  }

  Future<void> _loadCareState() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyName = prefs.getString(_prefBirdName);
    final legacyMode = prefs.getString(_prefBirdMode);
    final rawLegacyCare = prefs.getString(_prefCareItems);

    List<BirdProfile> loadedProfiles = [
      BirdProfile(
        id: 'bird_default',
        name: (legacyName != null && legacyName.isNotEmpty)
            ? legacyName
            : 'Murai Petir',
        species: 'Murai Batu',
        mode: (legacyMode != null && legacyMode.isNotEmpty)
            ? legacyMode
            : 'Harian',
      ),
    ];

    final rawProfiles = prefs.getString(_prefBirdProfiles);
    if (rawProfiles != null && rawProfiles.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawProfiles) as List<dynamic>;
        final parsed = decoded
            .whereType<Map<String, dynamic>>()
            .map(BirdProfile.fromJson)
            .where((b) => b.id.isNotEmpty)
            .toList();
        if (parsed.isNotEmpty) {
          loadedProfiles = parsed;
        }
      } catch (_) {}
    }

    final savedActiveId = prefs.getString(_prefActiveBirdId) ?? 'bird_default';
    final Map<String, List<Map<String, dynamic>>> careMap = {};

    final rawCareByBird = prefs.getString(_prefCareByBird);
    if (rawCareByBird != null && rawCareByBird.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCareByBird) as Map<String, dynamic>;
        decoded.forEach((key, val) {
          if (val is List) {
            careMap[key] = val
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList();
          }
        });
      } catch (_) {}
    } else if (rawLegacyCare != null && rawLegacyCare.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawLegacyCare) as List<dynamic>;
        careMap['bird_default'] = decoded
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      } catch (_) {}
    }

    for (final b in loadedProfiles) {
      careMap.putIfAbsent(b.id, _defaultCareItems);
    }

    if (!mounted) return;
    setState(() {
      _birdProfiles = loadedProfiles;
      _activeBirdId = (savedActiveId == 'all' ||
              loadedProfiles.any((b) => b.id == savedActiveId))
          ? savedActiveId
          : loadedProfiles.first.id;
      _careItemsByBird = careMap;
      final current = _activeBird;
      _birdName = current.name;
      _birdMode = current.mode;
      _careItems = careMap[current.id] ?? _defaultCareItems();
    });
  }

  Future<void> _saveCareState() async {
    final prefs = await SharedPreferences.getInstance();
    final currentId = _activeBird.id;
    _careItemsByBird[currentId] = _careItems;
    _birdProfiles = _birdProfiles
        .map(
          (b) => b.id == currentId
              ? b.copyWith(name: _birdName, mode: _birdMode)
              : b,
        )
        .toList();

    await prefs.setString(
      _prefBirdProfiles,
      jsonEncode(_birdProfiles.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(_prefActiveBirdId, _activeBirdId);
    await prefs.setString(_prefCareByBird, jsonEncode(_careItemsByBird));
    await prefs.setString(_prefBirdName, _birdName);
    await prefs.setString(_prefBirdMode, _birdMode);
    await prefs.setString(_prefCareItems, jsonEncode(_careItems));
  }

  Future<void> _selectBirdProfile(String id) async {
    setState(() {
      _activeBirdId = id;
      final current = _activeBird;
      _birdName = current.name;
      _birdMode = current.mode;
      _careItems = _careItemsByBird[current.id] ?? _defaultCareItems();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefActiveBirdId, _activeBirdId);
  }

  Future<void> _showAddBirdProfileDialog() async {
    final nameCtrl = TextEditingController();
    final speciesCtrl = TextEditingController(text: 'Murai Batu');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tambah Profil Burung (Gacoan)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nama Gacoan (cth: Kacer Raja)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: speciesCtrl,
              decoration: const InputDecoration(
                labelText: 'Jenis Burung (cth: Kacer / Cucak Ijo)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tambah'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final cleanName = nameCtrl.text.trim();
    if (cleanName.isEmpty) return;
    final newBird = BirdProfile(
      id: 'bird_${const Uuid().v4().substring(0, 8)}',
      name: cleanName,
      species: speciesCtrl.text.trim().isEmpty
          ? 'Burung Kicau'
          : speciesCtrl.text.trim(),
      mode: 'Harian',
    );
    setState(() {
      _birdProfiles = [..._birdProfiles, newBird];
      _careItemsByBird[newBird.id] = _defaultCareItems();
      _activeBirdId = newBird.id;
      _birdName = newBird.name;
      _birdMode = newBird.mode;
      _careItems = _careItemsByBird[newBird.id]!;
    });
    await _saveCareState();
  }

  Future<void> _toggleCareDone(int index) async {
    setState(() {
      final current = _careItems[index]['done'] == true;
      _careItems[index]['done'] = !current;
    });
    await _saveCareState();
  }

  Future<void> _resetDailyCare() async {
    setState(() {
      for (final item in _careItems) {
        item['done'] = false;
      }
    });
    await _saveCareState();
  }

  Future<void> _setBirdMode(String mode) async {
    setState(() => _birdMode = mode);
    await _saveCareState();
  }

  Future<void> _showEditBirdAndCareDialog({bool isNewCare = false}) async {
    final titleCtrl = TextEditingController(text: isNewCare ? '' : _birdName);
    final detailCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isNewCare ? 'Tambah Jadwal Rawatan / EF' : 'Ubah Nama Gacoan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: InputDecoration(
                labelText: isNewCare ? 'Nama Tugas (cth: Kroto Siang 12:00)' : 'Nama Burung',
              ),
            ),
            if (isNewCare) ...[
              const SizedBox(height: 10),
              TextField(
                controller: detailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Takaran / Catatan (cth: 1 sendok teh)',
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final text = titleCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      if (isNewCare) {
        _careItems.add({
          'title': text,
          'detail': detailCtrl.text.trim().isEmpty
              ? 'Rawatan rutin harian'
              : detailCtrl.text.trim(),
          'done': false,
        });
      } else {
        _birdName = text;
      }
    });
    await _saveCareState();
  }

  Future<void> _toggleNightStandby(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefNightStandby, enabled);
    if (enabled) {
      await WakelockPlus.enable();
    } else if (!_isPlayerOpen) {
      await WakelockPlus.disable();
    }
    if (!mounted) return;
    setState(() {
      _nightStandbyMode = enabled;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? 'Mode Siaga Malam aktif! Layar tetap terjaga agar jadwal 03:00 pagi pasti menyala.'
              : 'Mode Siaga Malam dimatikan.',
        ),
      ),
    );
  }

  void _checkActiveScheduleNow() {
    if (!mounted || _isPlayerOpen || _schedules.isEmpty) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (final baseDate in [today, yesterday]) {
      for (final s in _schedules) {
        if (!s.isActive || !s.days.contains(baseDate.weekday)) continue;

        final startDt = DateTime(
          baseDate.year,
          baseDate.month,
          baseDate.day,
          s.startHour,
          s.startMinute,
        );
        var endDt = DateTime(
          baseDate.year,
          baseDate.month,
          baseDate.day,
          s.endHour,
          s.endMinute,
        );
        if (!endDt.isAfter(startDt)) {
          endDt = endDt.add(const Duration(days: 1));
        }

        if (!now.isBefore(startDt) && now.isBefore(endDt)) {
          final triggerKey =
              '${s.id}_${baseDate.year}-${baseDate.month}-${baseDate.day}_${s.startHour}:${s.startMinute}';
          if (!_triggeredScheduleKeys.contains(triggerKey)) {
            _triggeredScheduleKeys.add(triggerKey);
            _openPlayerFromPayload(
              s.payload,
              scheduleName: s.name,
              isManualPreview: false,
            );
            return;
          }
        }
      }
    }
  }

  Future<List<Schedule>> _syncLocalOfflinePaths(List<Schedule> raw) async {
    final List<Schedule> synced = [];
    for (final s in raw) {
      String? validPath = s.localFilePath;
      if (validPath != null && !await File(validPath).exists()) {
        validPath = null;
        await DbService.instance.updateLocalFilePath(s.id, null);
      }
      if (validPath == null && s.platform == 'youtube') {
        final found =
            await OfflineService.instance.getExistingLocalPath(s.videoId);
        if (found != null) {
          validPath = found;
          await DbService.instance.updateLocalFilePath(s.id, found);
        }
      }
      synced.add(
        validPath != s.localFilePath
            ? s.copyWith(
                localFilePath: validPath,
                clearLocalFilePath: validPath == null,
              )
            : s,
      );
    }
    return synced;
  }

  Future<void> _reloadSchedules() async {
    unawaited(ApiService.instance.fetchRemoteConfig());
    unawaited(BmkgWeatherService.instance.ensureReminderScheduled());
    final schedules = await _syncLocalOfflinePaths(
      await DbService.instance.getAllSchedules(),
    );
    final activeForStandby = schedules.where((s) => s.isActive).toList();
    if (activeForStandby.isNotEmpty) {
      unawaited(
        NotifService.instance.startStandbyService(
          activeCount: activeForStandby.length,
          nextLabel: _nextAlarmCountdownLabel(activeForStandby),
        ),
      );
    } else {
      unawaited(NotifService.instance.stopStandbyService());
    }
    if (mounted) {
      setState(() {
        _schedules = schedules;
        _clockNow = DateTime.now();
      });
      _checkActiveScheduleNow();
    }
  }

  Future<void> _autoSetupBmkgOnFirstOpen() async {
    await BmkgWeatherService.instance.init();
    if (!BmkgWeatherService.instance.hasRegion &&
        (widget.initialPayload == null || widget.initialPayload!.isEmpty)) {
      final prefs = await SharedPreferences.getInstance();
      final alreadyPrompted = prefs.getBool('mendek_bmkg_loc_prompted_v1') ?? false;
      if (!alreadyPrompted) {
        await prefs.setBool('mendek_bmkg_loc_prompted_v1', true);
        await BmkgWeatherService.instance.detectRegionFromGps(
          requestPermission: true,
        );
      }
    }
    await _refreshBmkgForecast();
  }

  Future<void> _refreshBmkgForecast({
    bool forceFetch = false,
    bool forceSendNotification = false,
  }) async {
    if (!mounted) return;
    setState(() => _bmkgLoading = true);
    final summary =
        await BmkgWeatherService.instance.refreshForecastAndAutoNotify(
      forceFetch: forceFetch,
      forceSendNotification: forceSendNotification,
    );
    if (!mounted) return;
    setState(() {
      _bmkgSummary = summary;
      _bmkgAutoNotif = BmkgWeatherService.instance.autoNotifEnabled;
      _bmkgLoading = false;
    });
    if (summary != null && _autoShareBmkg) {
      final shared = await SocialService.instance.maybeAutoShareTomorrowBmkg(
        summary,
        birdTag: _activeBird.name,
      );
      if (shared && mounted) {
        unawaited(_refreshSocialFeed());
      }
    }
  }

  Future<void> _refreshSocialFeed({String? category}) async {
    final activeCat = category ?? _socialCategoryFilter;
    if (mounted) {
      setState(() => _socialLoading = true);
    }
    final list = await SocialService.instance.fetchFeed(category: activeCat);
    if (!mounted) return;
    setState(() {
      _socialPosts = list;
      _socialLoading = false;
    });
  }

  Future<void> _toggleAutoShareBmkg(bool enabled) async {
    await SocialService.instance.setAutoShareBmkg(enabled);
    if (!mounted) return;
    setState(() => _autoShareBmkg = enabled);
    if (enabled && _bmkgSummary != null) {
      final shared = await SocialService.instance.maybeAutoShareTomorrowBmkg(
        _bmkgSummary!,
        birdTag: _activeBird.name,
      );
      if (shared && mounted) {
        unawaited(_refreshSocialFeed());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Auto-Bagikan aktif! Info BMKG besok otomatis terbit ke Komunitas.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _shareBmkgToCommunityNow(BmkgTomorrowSummary summary) async {
    if (_socialPosting) return;
    setState(() => _socialPosting = true);
    final res = await SocialService.instance.createPost(
      category: 'cuaca',
      title: SocialService.instance.buildBmkgShareTitle(summary),
      content: SocialService.instance.buildBmkgShareBody(summary),
      authorRegion: summary.regionLabel,
      birdTag: _activeBird.name,
    );
    if (!mounted) return;
    setState(() => _socialPosting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.message)),
    );
    if (res.ok) {
      await _refreshSocialFeed();
      if (!mounted) return;
      setState(() => _activeTabIndex = 2);
    }
  }

  Future<void> _shareBmkgToExternalSocial(BmkgTomorrowSummary summary) async {
    final text = SocialService.instance.buildBmkgSocialShareCaption(
      summary,
      appName: _cfg.appName,
    );
    final ok = await ApiService.instance.shareToSocial(
      text: text,
      subject: SocialService.instance.buildBmkgShareTitle(summary),
    );
    if (!ok && mounted) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Teks info cuaca BMKG disalin ke clipboard.'),
        ),
      );
    }
  }

  Future<void> _detectBmkgLocation() async {
    if (!mounted) return;
    setState(() => _bmkgLoading = true);
    final result = await BmkgWeatherService.instance.detectRegionFromGps(
      requestPermission: true,
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _bmkgLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
      return;
    }
    await _refreshBmkgForecast(
      forceFetch: true,
      forceSendNotification: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  Future<void> _toggleBmkgAutoNotif(bool enabled) async {
    await BmkgWeatherService.instance.setAutoNotifEnabled(enabled);
    if (!mounted) return;
    setState(() => _bmkgAutoNotif = enabled);
    if (enabled && BmkgWeatherService.instance.hasRegion) {
      await _refreshBmkgForecast(forceSendNotification: false);
    }
  }

  Future<void> _pickBmkgNotifTime() async {
    final svc = BmkgWeatherService.instance;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: svc.notifHour, minute: svc.notifMinute),
      helpText: 'JAM NOTIF BMKG BESOK',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    await svc.setNotifTime(picked.hour, picked.minute);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Notifikasi harian BMKG untuk besok dijadwalkan jam ${svc.formattedNotifTime}.',
        ),
      ),
    );
  }

  Future<void> _openBmkgRegionPickerSheet() async {
    List<RegionOption> provinces = [];
    List<RegionOption> regencies = [];
    List<RegionOption> districts = [];
    List<RegionOption> villages = [];
    RegionOption? selProv;
    RegionOption? selReg;
    RegionOption? selDist;
    RegionOption? selVil;
    bool loading = true;
    String? err;

    try {
      provinces = await BmkgWeatherService.instance.fetchProvinces();
      loading = false;
    } catch (e) {
      loading = false;
      err = 'Gagal memuat daftar wilayah: $e';
    }
    if (!mounted) return;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                24 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pilih Wilayah BMKG',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Data prakiraan cuaca esok diambil langsung dari server resmi BMKG per kelurahan/desa.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                    ),
                    const SizedBox(height: 14),
                    if (err != null)
                      Text(
                        err!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                      ),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (provinces.isNotEmpty) ...[
                      DropdownButtonFormField<RegionOption>(
                        isExpanded: true,
                        value: selProv,
                        decoration: const InputDecoration(
                          labelText: '1. Provinsi',
                          border: OutlineInputBorder(),
                        ),
                        items: provinces
                            .map(
                              (p) => DropdownMenuItem(
                                value: p,
                                child: Text(p.name, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                        onChanged: (val) async {
                          if (val == null) return;
                          setSheetState(() {
                            selProv = val;
                            selReg = null;
                            selDist = null;
                            selVil = null;
                            regencies = [];
                            districts = [];
                            villages = [];
                            loading = true;
                            err = null;
                          });
                          try {
                            final list = await BmkgWeatherService.instance
                                .fetchRegencies(val.code);
                            setSheetState(() {
                              regencies = list;
                              loading = false;
                            });
                          } catch (e) {
                            setSheetState(() {
                              loading = false;
                              err = '$e';
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (regencies.isNotEmpty) ...[
                      DropdownButtonFormField<RegionOption>(
                        isExpanded: true,
                        value: selReg,
                        decoration: const InputDecoration(
                          labelText: '2. Kota / Kabupaten',
                          border: OutlineInputBorder(),
                        ),
                        items: regencies
                            .map(
                              (r) => DropdownMenuItem(
                                value: r,
                                child: Text(r.name, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                        onChanged: (val) async {
                          if (val == null) return;
                          setSheetState(() {
                            selReg = val;
                            selDist = null;
                            selVil = null;
                            districts = [];
                            villages = [];
                            loading = true;
                            err = null;
                          });
                          try {
                            final list = await BmkgWeatherService.instance
                                .fetchDistricts(val.code);
                            setSheetState(() {
                              districts = list;
                              loading = false;
                            });
                          } catch (e) {
                            setSheetState(() {
                              loading = false;
                              err = '$e';
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (districts.isNotEmpty) ...[
                      DropdownButtonFormField<RegionOption>(
                        isExpanded: true,
                        value: selDist,
                        decoration: const InputDecoration(
                          labelText: '3. Kecamatan',
                          border: OutlineInputBorder(),
                        ),
                        items: districts
                            .map(
                              (d) => DropdownMenuItem(
                                value: d,
                                child: Text(d.name, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                        onChanged: (val) async {
                          if (val == null) return;
                          setSheetState(() {
                            selDist = val;
                            selVil = null;
                            villages = [];
                            loading = true;
                            err = null;
                          });
                          try {
                            final list = await BmkgWeatherService.instance
                                .fetchVillages(val.code);
                            setSheetState(() {
                              villages = list;
                              loading = false;
                            });
                          } catch (e) {
                            setSheetState(() {
                              loading = false;
                              err = '$e';
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (villages.isNotEmpty) ...[
                      DropdownButtonFormField<RegionOption>(
                        isExpanded: true,
                        value: selVil,
                        decoration: const InputDecoration(
                          labelText: '4. Kelurahan / Desa',
                          border: OutlineInputBorder(),
                        ),
                        items: villages
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(v.name, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                        onChanged: (val) {
                          setSheetState(() => selVil = val);
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _appleBlue),
                        onPressed: selVil == null
                            ? null
                            : () async {
                                final label =
                                    '${selVil!.name}, ${selDist?.name ?? ''}, ${selReg?.name ?? ''}';
                                await BmkgWeatherService.instance.setManualRegion(
                                  adm4: selVil!.code,
                                  regionLabel: label,
                                );
                                if (ctx.mounted) {
                                  Navigator.of(ctx).pop(true);
                                }
                              },
                        child: const Text(
                          'Simpan Wilayah & Ambil Cuaca BMKG',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (saved == true && mounted) {
      await _refreshBmkgForecast(
        forceFetch: true,
        forceSendNotification: true,
      );
    }
  }

  void _openBmkgTimelineDialog() {
    final summary = _bmkgSummary;
    if (summary == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          'BMKG Besok (${summary.tomorrowDateLabel})',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.regionLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1D4ED8),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  summary.birdCareTip,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF3A3A3C)),
                ),
                const Divider(height: 18),
                ...summary.tomorrowSlots.map((slot) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 48,
                          child: Text(
                            slot.hourLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Icon(
                          slot.isRain
                              ? Icons.umbrella_rounded
                              : (slot.isHotOrSunny
                                  ? Icons.wb_sunny_rounded
                                  : Icons.cloud_rounded),
                          size: 18,
                          color: slot.isRain
                              ? const Color(0xFF2563EB)
                              : (slot.isHotOrSunny
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF64748B)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            slot.weatherDesc,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${slot.tempC}°C',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(
                _refreshBmkgForecast(
                  forceFetch: true,
                  forceSendNotification: true,
                ),
              );
            },
            child: const Text('Kirim Notif Tes'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPlayerFromPayload(
    String payload, {
    String? scheduleName,
    bool isManualPreview = false,
  }) async {
    if (!mounted) return;
    if (payload == 'bmkg_cuaca') {
      setState(() => _activeTabIndex = 0);
      if (_bmkgSummary != null) {
        _openBmkgTimelineDialog();
      } else {
        unawaited(_refreshBmkgForecast(forceFetch: true));
      }
      return;
    }
    if (_isPlayerOpen) return;

    String? resolvedName = scheduleName;
    if (resolvedName == null) {
      final parts = payload.split('|');
      if (parts.isNotEmpty) {
        final found = _schedules.where((s) => s.id == parts[0]);
        if (found.isNotEmpty) {
          resolvedName = found.first.name;
        }
      }
    }

    _isPlayerOpen = true;

    try {
      await Navigator.of(context).push(
        buildPremiumRoute(
          PlayerScreen(
            payload: payload,
            scheduleName: resolvedName,
            isManualPreview: isManualPreview,
          ),
        ),
      );
    } finally {
      _isPlayerOpen = false;
      if (_nightStandbyMode) {
        await WakelockPlus.enable();
      }
    }
  }

  Future<void> _triggerTestAlarm(Schedule schedule) async {
    await NotifService.instance.scheduleTestAlarmInSeconds(
      schedule,
      seconds: 10,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 6),
        content: Text(
          'Tes alarm 10 detik dijadwalkan! Silakan keluar aplikasi atau kunci layar — pemutar akan menyala otomatis dalam 10 detik.',
        ),
      ),
    );
  }

  Future<void> _toggleSchedule(Schedule schedule, bool value) async {
    if (value) {
      _triggeredScheduleKeys.removeWhere((k) => k.startsWith('${schedule.id}_'));
    }
    await DbService.instance.toggleScheduleActive(schedule.id, value);
    final updated = schedule.copyWith(isActive: value);
    await NotifService.instance.scheduleNotificationsFor(updated);
    await _reloadSchedules();
  }

  Future<void> _deleteSchedule(Schedule schedule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Hapus Jadwal?'),
        content: Text(
          'Jadwal "${schedule.name}" (${schedule.timeRangeText}) akan dihapus permanen.',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Batal',
              style: TextStyle(fontSize: 16, color: _appleBlue),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B30),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Hapus', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await NotifService.instance.cancelSchedule(schedule.id);
      await DbService.instance.deleteSchedule(schedule.id);
      await _reloadSchedules();
    }
  }

  Future<void> _downloadOffline(Schedule schedule) async {
    if (!_cfg.enableOfflineDownload) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fitur unduh offline sedang dinonaktifkan oleh admin.'),
        ),
      );
      return;
    }
    if (schedule.platform != 'youtube') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unduh offline MP4 saat ini tersedia untuk video YouTube.'),
        ),
      );
      return;
    }
    if (_downloadingIds.contains(schedule.id)) return;

    setState(() {
      _downloadingIds.add(schedule.id);
      _downloadProgress[schedule.id] = 0.0;
    });

    try {
      final path = await OfflineService.instance.downloadYoutubeVideo(
        schedule.videoId,
        onProgress: (prog) {
          if (mounted) {
            setState(() {
              _downloadProgress[schedule.id] = prog;
            });
          }
        },
      );
      await DbService.instance.updateLocalFilePath(schedule.id, path);
      await _reloadSchedules();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '"${schedule.name}" berhasil disimpan untuk pemutaran offline!',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengunduh video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingIds.remove(schedule.id);
          _downloadProgress.remove(schedule.id);
        });
      }
    }
  }

  Future<void> _deleteOfflineFile(Schedule schedule) async {
    await OfflineService.instance.deleteOfflineVideo(schedule.videoId);
    await DbService.instance.updateLocalFilePath(schedule.id, null);
    await _reloadSchedules();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File offline "${schedule.name}" dihapus.')),
      );
    }
  }

  int? _getExpiringDaysLeft() {
    final rawExp = ApiService.instance.session?.expiresAt;
    if (rawExp == null || rawExp.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(rawExp.trim().replaceFirst(' ', 'T'));
    if (parsed == null) return null;
    final diffHours = parsed.difference(DateTime.now()).inHours;
    if (diffHours > 72) return null;
    return (diffHours / 24).ceil();
  }

  Future<void> _launchWhatsAppRenew() async {
    final session = ApiService.instance.session;
    final phone = _cfg.waNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final msg = Uri.encodeComponent(
      'Halo Admin ${_cfg.appName}, Key sewa saya (${session?.key ?? ''}) akan segera habis. Mohon info perpanjang.',
    );
    final uri = Uri.parse('https://wa.me/$phone?text=$msg');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _startInAppApkUpdate() async {
    if (_downloadingApkUpdate) return;
    final directApk = ApiService.instance.effectiveApkDownloadUrl.trim();
    if (directApk.toLowerCase().startsWith('https://') &&
        directApk.toLowerCase().contains('.apk')) {
      setState(() {
        _downloadingApkUpdate = true;
        _apkDownloadProgress = 0.0;
      });
      final res = await ApiService.instance.downloadAndInstallApkUpdate(
        url: directApk,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _apkDownloadProgress = p);
        },
      );
      if (!mounted) return;
      setState(() => _downloadingApkUpdate = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            res.started
                ? 'Installer APK terbuka. Ketuk Update agar jadwal & data tetap aman!'
                : (res.message.isNotEmpty
                    ? res.message
                    : 'Gagal memulai installer update.'),
          ),
        ),
      );
      return;
    }
    final fallback = directApk.startsWith('https://')
        ? directApk
        : (_cfg.githubRepo.trim().isNotEmpty
            ? 'https://github.com/${_cfg.githubRepo.trim()}/releases/latest'
            : 'https://limopancer.com/mendek/');
    final uri = Uri.tryParse(fallback);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openLiveModule(LiveModuleItem mod) async {
    final raw = mod.url.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL modul tidak valid (wajib HTTPS).')),
      );
      return;
    }
    if (mod.openMode == 'external') {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
      return;
    }
    await Navigator.of(context).push(
      buildPremiumRoute(
        LiveModuleWebViewScreen(
          title: mod.title,
          url: raw,
          accentColor: _appleBlue,
        ),
      ),
    );
  }

  Future<void> _installCatalogPreset(CatalogPreset preset) async {
    final parsed = UrlHelper.parseUrl(preset.url);
    final platform = parsed?.platform ??
        (preset.platform == 'tiktok' ? 'tiktok' : 'youtube');
    final videoId = parsed?.videoId ?? preset.id;
    final cleanUrl = parsed?.originalUrl ?? preset.url;

    final schedule = Schedule(
      id: const Uuid().v4(),
      name: preset.title,
      url: cleanUrl,
      platform: platform,
      videoId: videoId,
      startHour: 3,
      startMinute: 0,
      endHour: 7,
      endMinute: 0,
      days: const [1, 2, 3, 4, 5, 6, 7],
      isActive: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      playMinutes: preset.recommendedPlayMin > 0 ? preset.recommendedPlayMin : 15,
      pauseMinutes: preset.recommendedPauseMin >= 0 ? preset.recommendedPauseMin : 5,
      birdId: _activeBirdId == 'all' ? 'bird_default' : _activeBirdId,
      fadeInSeconds: preset.recommendedFadeSec,
    );

    await DbService.instance.insertSchedule(schedule);
    await NotifService.instance.scheduleNotificationsFor(schedule);
    await _reloadSchedules();

    if (!mounted) return;
    if (platform == 'youtube' && _cfg.enableOfflineDownload) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '"${preset.title}" dipasang! Mulai mengunduh offline ke HP...',
          ),
        ),
      );
      unawaited(_downloadOffline(schedule));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${preset.title}" berhasil dipasang ke jadwal!'),
        ),
      );
    }
  }

  Future<void> _openAddEdit([Schedule? schedule]) async {
    final res = await Navigator.of(context).push<AddEditResult>(
      buildPremiumRoute(
        AddEditScreen(
          existingSchedule: schedule,
          initialBirdId: _activeBirdId == 'all' ? 'bird_default' : _activeBirdId,
          birdProfiles: _birdProfiles,
        ),
      ),
    );
    if (res != null) {
      if (schedule != null) {
        _triggeredScheduleKeys.removeWhere(
          (k) => k.startsWith('${schedule.id}_'),
        );
      }
      await _reloadSchedules();
      if (res.autoDownloadOffline &&
          res.schedule.platform == 'youtube' &&
          mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Jadwal "${res.schedule.name}" tersimpan! Mengunduh video offline...',
            ),
          ),
        );
        unawaited(_downloadOffline(res.schedule));
      }
    }
  }

  Future<void> _recheckPermissions() async {
    final perms = await NotifService.instance.requestRequiredPermissions();
    if (!mounted) return;
    setState(() {
      _permStatus = perms;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          perms.allGranted
              ? 'Semua 5 izin alarm sudah aktif! Aplikasi siap membuka video otomatis.'
              : 'Izin dasar diperiksa. Untuk buka otomatis saat layar mati, aktifkan juga izin "Tampil di Atas Aplikasi Lain" di tab Akun.',
        ),
      ),
    );
  }

  Future<void> _requestOverlayPermission() async {
    await NotifService.instance.requestSystemAlertWindowPermission();
    await _refreshPermissionStatusOnly();
  }

  Future<void> _requestFullScreenPermission() async {
    await NotifService.instance.openFullScreenIntentSettings();
    await _refreshPermissionStatusOnly();
  }

  Future<void> _logoutAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Keluar / Ganti Key?'),
        content: const Text(
          'Anda akan keluar ke halaman Login Key. Jadwal masteran Anda tetap aman tersimpan di HP.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Batal', style: TextStyle(color: _appleBlue)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B30),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Keluar'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ApiService.instance.logout();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        buildPremiumRoute(const LoginScreen()),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockWatcherTimer?.cancel();
    _autoSyncTimer?.cancel();
    _notifSub?.cancel();
    super.dispose();
  }

  String _heroCycleSummary(List<Schedule> activeSchedules) {
    if (activeSchedules.isEmpty) return '15m / 5m';
    final first = activeSchedules.first;
    if (first.hasInterval) {
      return '${first.playMinutes}m / ${first.pauseMinutes}m';
    }
    return 'Nonstop';
  }

  String _nextAlarmCountdownLabel(List<Schedule> activeSchedules) {
    if (activeSchedules.isEmpty) {
      return 'Belum ada jadwal aktif.';
    }
    final now = _clockNow;
    DateTime? closest;
    Schedule? closestSchedule;

    for (final s in activeSchedules) {
      if (s.days.isEmpty) continue;
      for (int offset = 0; offset <= 7; offset++) {
        final dayDate = DateTime(now.year, now.month, now.day + offset);
        if (!s.days.contains(dayDate.weekday)) continue;
        final candidate = DateTime(
          dayDate.year,
          dayDate.month,
          dayDate.day,
          s.startHour,
          s.startMinute,
        );
        if (candidate.isAfter(now)) {
          if (closest == null || candidate.isBefore(closest)) {
            closest = candidate;
            closestSchedule = s;
          }
          break;
        }
      }
    }

    if (closest == null || closestSchedule == null) {
      return 'Jadwal aktif (${activeSchedules.first.formattedStartTime} - ${activeSchedules.first.formattedEndTime})';
    }

    final diff = closest.difference(now);
    final totalSec = diff.inSeconds < 0 ? 0 : diff.inSeconds;
    final days = totalSec ~/ 86400;
    final hours = (totalSec % 86400) ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    final secs = totalSec % 60;

    final countdown = days > 0
        ? '${days}h ${hours.toString().padLeft(2, '0')}j ${mins.toString().padLeft(2, '0')}m'
        : '${hours.toString().padLeft(2, '0')}j ${mins.toString().padLeft(2, '0')}m ${secs.toString().padLeft(2, '0')}d';

    return 'Berikutnya: ${closestSchedule.name} (${closestSchedule.formattedStartTime}) · $countdown lagi';
  }

  Widget _buildEngineDiagnosticCard(List<Schedule> activeSchedules) {
    final bool bridgeReady = _nativeBridgeActive != false;
    final String nextText = _nextAlarmCountdownLabel(activeSchedules);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bridgeReady ? Colors.white : const Color(0xFFFFF1F0),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: bridgeReady
              ? const Color(0xFFDBEAFE)
              : const Color(0xFFFFCCC7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: bridgeReady
                      ? const Color(0xFFEFF6FF)
                      : const Color(0xFFFFE4E6),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  bridgeReady
                      ? Icons.alarm_on_rounded
                      : Icons.error_outline_rounded,
                  color: bridgeReady
                      ? _appleBlue
                      : const Color(0xFFFF3B30),
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _nativeBridgeActive == null
                          ? 'Memeriksa Mesin Alarm Native...'
                          : bridgeReady
                              ? 'Mesin Alarm Native Aktif'
                              : 'Mesin Native Belum Terpasang di APK Ini',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: bridgeReady
                            ? const Color(0xFF1C1C1E)
                            : const Color(0xFFB91C1C),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bridgeReady
                          ? nextText
                          : 'Folder android/ terbaru belum ikut ter-compile di APK ini. Unggah ulang folder android/ & lib/ ke GitHub.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: bridgeReady
                            ? const Color(0xFF3A3A3C)
                            : const Color(0xFFB91C1C),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeSchedules = _schedules.where((s) => s.isActive).toList();
    final activeCount = activeSchedules.length;
    final offlineCount = _schedules.where((s) => s.isOfflineReady).length;

    return Scaffold(
      extendBody: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(68),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(232),
                border: const Border(
                  bottom: BorderSide(color: Color(0xFFE5E5EA), width: 1),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _appleBlue,
                              Color.lerp(_appleBlue, Colors.white, 0.2)!,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: _appleBlue.withAlpha(65),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: _cfg.logoUrl.startsWith('https://')
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(11),
                                child: Image.network(
                                  _cfg.logoUrl,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.cloud_queue_rounded,
                                    size: 22,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : const Icon(
                                Icons.cloud_queue_rounded,
                                size: 22,
                                color: Colors.white,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _cfg.appName,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1C1C1E),
                                letterSpacing: -0.3,
                              ),
                            ),
                            Text(
                              ApiService.instance.session?.labelUser ??
                                  _cfg.heroTitle,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF6E6E73),
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _activeTabIndex = 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _permStatus?.allGranted == true
                                ? const Color(0xFFEFF6FF)
                                : const Color(0xFFFFFBEB),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _permStatus?.allGranted == true
                                  ? const Color(0xFF93C5FD)
                                  : const Color(0xFFFCD34D),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _permStatus?.allGranted == true
                                    ? Icons.verified_user_rounded
                                    : Icons.shield_outlined,
                                size: 16,
                                color: _permStatus?.allGranted == true
                                    ? _appleBlue
                                    : const Color(0xFFB45309),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _permStatus?.allGranted == true
                                    ? 'Siap'
                                    : 'Izin',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: _permStatus?.allGranted == true
                                      ? _appleBlue
                                      : const Color(0xFFB45309),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: _appleBlue,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: () => _openAddEdit(),
                          borderRadius: BorderRadius.circular(20),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.add_rounded,
                                    color: Colors.white, size: 18),
                                SizedBox(width: 4),
                                Text(
                                  'Tambah',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _IosBottomMenuBar(
        activeIndex: _activeTabIndex,
        activeCount: activeCount,
        offlineCount: offlineCount,
        socialCount: _socialPosts.length,
        allPermissionsGranted: _permStatus?.allGranted == true,
        accentColor: _appleBlue,
        onSelectTab: (idx) {
          setState(() => _activeTabIndex = idx);
          if (idx == 2) {
            unawaited(_refreshSocialFeed());
          }
        },
        onAddTap: () => _openAddEdit(),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: _appleBlue))
          : RefreshIndicator(
              color: _appleBlue,
              onRefresh: () async {
                await _reloadSchedules();
                await _syncLiveFromServerAndGithub(forceReleaseCheck: true);
              },
              child: _activeTabIndex == 0
                  ? _buildSchedulesTab(activeSchedules, activeCount)
                  : _activeTabIndex == 1
                      ? _buildOfflineTab()
                      : _activeTabIndex == 2
                          ? _buildCommunityTab()
                          : _activeTabIndex == 3
                              ? _buildSummaryTab(activeSchedules)
                              : _buildAccountAndPermissionsTab(),
            ),
    );
  }

  Widget _buildBmkgWeatherCard() {
    final summary = _bmkgSummary;
    final svc = BmkgWeatherService.instance;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: summary != null
              ? const Color(0xFF93C5FD)
              : const Color(0xFFE5E5EA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  summary != null && summary.rainSlots.isNotEmpty
                      ? Icons.umbrella_rounded
                      : Icons.wb_sunny_rounded,
                  color: summary != null && summary.rainSlots.isNotEmpty
                      ? const Color(0xFF0284C7)
                      : const Color(0xFFD97706),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary != null
                          ? 'Cuaca BMKG Besok (${summary.tomorrowDateLabel})'
                          : 'Auto Notif Cuaca BMKG Besok',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    Text(
                      svc.hasRegion
                          ? (summary?.regionLabel ?? svc.regionLabel)
                          : 'Deteksi lokasi HP untuk info jam hujan & panas esok',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6E6E73),
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoSwitch(
                value: _bmkgAutoNotif,
                activeColor: _appleBlue,
                onChanged: _toggleBmkgAutoNotif,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_bmkgLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Mengambil prakiraan BMKG sesuai wilayah...',
                    style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                  ),
                ],
              ),
            )
          else if (summary != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.wb_sunny_rounded,
                        size: 16,
                        color: Color(0xFFD97706),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Panas/Cerah Besok: ${summary.hotHoursText}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        Icons.water_drop_rounded,
                        size: 16,
                        color: Color(0xFF2563EB),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Hujan Besok: ${summary.rainHoursText}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    summary.birdCareTip,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF475569),
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _appleBlue,
                  side: const BorderSide(color: Color(0xFF93C5FD)),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _bmkgLoading ? null : _detectBmkgLocation,
                icon: const Icon(Icons.my_location_rounded, size: 15),
                label: const Text(
                  'Deteksi GPS',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1E293B),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _openBmkgRegionPickerSheet,
                icon: const Icon(Icons.location_city_rounded, size: 15),
                label: const Text(
                  'Pilih Wilayah',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1E293B),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _pickBmkgNotifTime,
                icon: const Icon(Icons.notifications_active_rounded, size: 15),
                label: Text(
                  'Jam ${svc.formattedNotifTime}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (summary != null)
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEFF6FF),
                    foregroundColor: _appleBlue,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _openBmkgTimelineDialog,
                  icon: const Icon(Icons.schedule_rounded, size: 15),
                  label: const Text(
                    'Detail & Tes Notif',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              if (summary != null && _cfg.enableSocialFeed)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _appleBlue,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _socialPosting
                      ? null
                      : () => _shareBmkgToCommunityNow(summary),
                  icon: const Icon(Icons.forum_rounded, size: 14),
                  label: Text(
                    _socialPosting ? 'Mengirim...' : 'Pos ke Komunitas',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (summary != null)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF047857),
                    side: const BorderSide(color: Color(0xFFA7F3D0)),
                    backgroundColor: const Color(0xFFECFDF5),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _shareBmkgToExternalSocial(summary),
                  icon: const Icon(Icons.share_rounded, size: 14),
                  label: const Text(
                    'Share WA / Sosmed',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
          if (_cfg.enableSocialFeed) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 16, color: _appleBlue),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Auto-bagikan info cuaca besok ke Komunitas tiap hari',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                  Transform.scale(
                    scale: 0.82,
                    child: CupertinoSwitch(
                      value: _autoShareBmkg,
                      activeColor: _appleBlue,
                      onChanged: _toggleAutoShareBmkg,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSchedulesTab(List<Schedule> activeSchedules, int activeCount) {
    final int? expiringDays = _getExpiringDaysLeft();
    final List<CatalogPreset> catalog = ApiService.instance.catalog;
    final bool updateAvailable = ApiService.instance.isUpdateAvailable(
      installedVersion: _installedAppVersion,
    );
    final List<Schedule> visibleSchedules = _filteredSchedules;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 116),
      children: [
        if (updateAvailable)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF93C5FD), width: 1.5),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _appleBlue,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.system_update_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Update APK v${ApiService.instance.effectiveUpdateVersion} Tersedia',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1E3A8A),
                            ),
                          ),
                          Text(
                            _downloadingApkUpdate
                                ? 'Mengunduh update otomatis (${(_apkDownloadProgress * 100).round()}%)... Data jadwal aman.'
                                : 'Versi terpasang v$_installedAppVersion. Ketuk 1x untuk update langsung tanpa hapus data.',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: _appleBlue,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed:
                          _downloadingApkUpdate ? null : _startInAppApkUpdate,
                      child: Text(
                        _downloadingApkUpdate
                            ? '${(_apkDownloadProgress * 100).round()}%'
                            : 'Update 1-Klik',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_downloadingApkUpdate) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _apkDownloadProgress > 0
                          ? _apkDownloadProgress
                          : null,
                      minHeight: 6,
                      color: _appleBlue,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),
        if (expiringDays != null)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Color(0xFFB45309),
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        expiringDays <= 0
                            ? 'Masa Sewa Key Berakhir Hari Ini'
                            : 'Masa Sewa Key Tinggal $expiringDays Hari Lagi',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Berakhir pada ${ApiService.instance.session?.expiresAt?.split(' ').first ?? '-'}. Perpanjang sekarang agar jadwal alarm masteran tidak terhenti.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF78350F),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF059669),
                      minimumSize: const Size(0, 42),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _launchWhatsAppRenew,
                    icon: const Icon(Icons.chat_rounded, size: 18),
                    label: const Text(
                      'Perpanjang via WhatsApp',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_cfg.announcement.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF93C5FD)),
            ),
            child: Row(
              children: [
                Icon(Icons.campaign_rounded, color: _appleBlue, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _cfg.announcement,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_cfg.liveModules.where((m) => m.enabled).isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.bolt_rounded, color: _appleBlue, size: 20),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Fitur Live dari Server',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),
                    Text(
                      'Rev #${_cfg.otaRevision}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8E8E93),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ..._cfg.liveModules.where((m) => m.enabled).map(
                  (mod) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _openLiveModule(mod),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  mod.badge,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: _appleBlue,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      mod.title,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF1C1C1E),
                                      ),
                                    ),
                                    if (mod.subtitle.isNotEmpty)
                                      Text(
                                        mod.subtitle,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF6E6E73),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Icon(
                                mod.openMode == 'external'
                                    ? Icons.open_in_new_rounded
                                    : Icons.chevron_right_rounded,
                                color: _appleBlue,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E5EA)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.tune_rounded, color: _appleBlue, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$_birdName • Mode $_birdMode',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    Text(
                      '${_careItems.where((e) => e['done'] != true).length} jadwal rawat / EF belum selesai',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6E6E73),
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _appleBlue,
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => setState(() => _activeTabIndex = 3),
                child: const Text(
                  'Setting',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        if (_permStatus != null && !_permStatus!.allGranted)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFFCD34D), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(8),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFB45309),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Izin Alarm Otomatis Belum Lengkap',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Agar APK dapat menyala otomatis jam 3 pagi tanpa disentuh, aktifkan izin Notifikasi, Alarm Presisi, Baterai Tanpa Batas, dan Tampil di Atas Aplikasi Lain.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF3A3A3C)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: _appleBlue),
                        onPressed: () => setState(() => _activeTabIndex = 4),
                        icon: const Icon(Icons.shield_outlined, size: 18),
                        label: const Text('Atur Semua Izin'),
                      ),
                    ),
                    if (!_permStatus!.systemAlertWindowGranted) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEFF6FF),
                          foregroundColor: _appleBlue,
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: _requestOverlayPermission,
                        child: const Text(
                          'Tampil Atas',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        CloudHeroBanner(
          activeCount: activeCount,
          totalCount: _schedules.length,
          cycleSummaryLabel: _heroCycleSummary(activeSchedules),
          accentColor: _appleBlue,
          heroTitle: _cfg.heroTitle,
          heroSubtitle: _cfg.heroSubtitle,
          enableCloudAnim: _cfg.enableCloudAnim,
          nextScheduleLabel: _nextAlarmCountdownLabel(activeSchedules),
        ),
        _buildEngineDiagnosticCard(activeSchedules),
        _buildBmkgWeatherCard(),
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _nightStandbyMode
                  ? const Color(0xFF93C5FD)
                  : const Color(0xFFE5E5EA),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _nightStandbyMode
                      ? const Color(0xFFEFF6FF)
                      : const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.nightlight_round,
                  color:
                      _nightStandbyMode ? _appleBlue : const Color(0xFF6E6E73),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mode Siaga Malam (Anti-Tidur)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    Text(
                      'Biarkan aplikasi terbuka saat dicas agar jam 03:00 100% berputar.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6E6E73),
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoSwitch(
                value: _nightStandbyMode,
                activeColor: _appleBlue,
                onChanged: _toggleNightStandby,
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('Semua (${_schedules.length})'),
                  selected: _activeBirdId == 'all',
                  selectedColor: _appleBlue,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _activeBirdId == 'all'
                        ? Colors.white
                        : const Color(0xFF1C1C1E),
                  ),
                  onSelected: (_) => unawaited(_selectBirdProfile('all')),
                ),
                const SizedBox(width: 8),
                ..._birdProfiles.map((bird) {
                  final selected = _activeBirdId == bird.id;
                  final count =
                      _schedules.where((s) => s.birdId == bird.id).length;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${bird.name} ($count)'),
                      selected: selected,
                      selectedColor: _appleBlue,
                      labelStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF1C1C1E),
                      ),
                      onSelected: (_) => unawaited(_selectBirdProfile(bird.id)),
                    ),
                  );
                }),
                ActionChip(
                  avatar: Icon(Icons.add_rounded, size: 16, color: _appleBlue),
                  label: const Text(
                    'Burung',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  onPressed: _showAddBirdProfileDialog,
                ),
              ],
            ),
          ),
        ),
        if (visibleSchedules.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE5E5EA)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(8),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(
                    Icons.cloud_outlined,
                    size: 46,
                    color: _appleBlue,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Belum Ada Jadwal Masteran',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1C1C1E),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tekan tombol "+ Tambah" di menu bar untuk memasukkan link YouTube atau TikTok (termasuk vt.tiktok.com).',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Color(0xFF6E6E73)),
                ),
              ],
            ),
          )
        else
          ...visibleSchedules.map((schedule) {
            String? birdTag;
            if (_birdProfiles.length > 1) {
              for (final b in _birdProfiles) {
                if (b.id == schedule.birdId) {
                  birdTag = b.name;
                  break;
                }
              }
            }
            return _ScheduleCard(
              schedule: schedule,
              birdLabel: birdTag,
              accentColor: _appleBlue,
              onToggle: (val) => _toggleSchedule(schedule, val),
              onPlayNow: () => _openPlayerFromPayload(
                schedule.payload,
                scheduleName: schedule.name,
                isManualPreview: true,
              ),
              onTestAlarm: () => _triggerTestAlarm(schedule),
              onShare: () => _openShareScheduleSheet(schedule, birdLabel: birdTag),
              onEdit: () => _openAddEdit(schedule),
              onDelete: () => _deleteSchedule(schedule),
            );
          }),
        if (catalog.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.library_music_rounded, color: _appleBlue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Katalog Masteran Rekomendasi Admin (${catalog.length})',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ketuk 1 kali untuk langsung pasang jadwal & unduh offline ke HP.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                ),
                const SizedBox(height: 12),
                ...catalog.map(
                  (preset) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE5E5EA)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                preset.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${preset.species} • Putar ${preset.recommendedPlayMin}m / Jeda ${preset.recommendedPauseMin}m',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _appleBlue,
                            minimumSize: const Size(0, 38),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () => _installCatalogPreset(preset),
                          child: Text(
                            preset.platform == 'youtube' &&
                                    _cfg.enableOfflineDownload
                                ? 'Pasang & Unduh'
                                : 'Pasang',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOfflineTab() {
    final youtubeSchedules =
        _schedules.where((s) => s.platform == 'youtube').toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 116),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            'Masteran Offline (Tanpa Kuota)',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1C1C1E),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 16),
          child: Text(
            'Unduh video masteran YouTube ke memori HP agar tetap berputar otomatis saat sinyal hilang atau kuota habis.',
            style: TextStyle(fontSize: 13, color: Color(0xFF6E6E73)),
          ),
        ),
        if (!_cfg.enableOfflineDownload)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF1F0),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFFFCCC7)),
            ),
            child: const Text(
              'Fitur unduh video offline sedang dinonaktifkan sementara oleh Admin melalui server.',
              style: TextStyle(
                color: Color(0xFFB91C1C),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (youtubeSchedules.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: Column(
              children: [
                Icon(Icons.cloud_download_rounded, size: 48, color: _appleBlue),
                const SizedBox(height: 12),
                const Text(
                  'Belum Ada Jadwal YouTube',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1C1C1E),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Tambahkan jadwal video YouTube terlebih dahulu untuk mengunduhnya menjadi masteran offline.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF6E6E73)),
                ),
              ],
            ),
          )
        else
          ...youtubeSchedules.map((s) {
            final isDownloading = _downloadingIds.contains(s.id);
            final progress = _downloadProgress[s.id] ?? 0.0;
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: s.isOfflineReady
                      ? const Color(0xFF93C5FD)
                      : const Color(0xFFE5E5EA),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: s.isOfflineReady
                              ? const Color(0xFFEFF6FF)
                              : const Color(0xFFF2F2F7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          s.isOfflineReady
                              ? Icons.offline_pin_rounded
                              : Icons.cloud_download_rounded,
                          color:
                              s.isOfflineReady ? _appleBlue : const Color(0xFF6E6E73),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1C1C1E),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.isOfflineReady
                                  ? 'Tersimpan Offline • ${s.timeRangeText}'
                                  : 'Belum diunduh • ID: ${s.videoId}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: s.isOfflineReady
                                    ? _appleBlue
                                    : const Color(0xFF6E6E73),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: progress > 0 ? progress : null,
                        minHeight: 8,
                        color: _appleBlue,
                        backgroundColor: const Color(0xFFEFF6FF),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      progress > 0
                          ? 'Mengunduh ${(progress * 100).round()}%...'
                          : 'Menyiapkan stream video YouTube...',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6E6E73),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (!s.isOfflineReady)
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: _appleBlue,
                                minimumSize: const Size(0, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: _cfg.enableOfflineDownload
                                  ? () => _downloadOffline(s)
                                  : null,
                              icon: const Icon(Icons.download_rounded, size: 20),
                              label: const Text(
                                'Unduh ke HP (Offline)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          )
                        else ...[
                          Expanded(
                            child: FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFEFF6FF),
                                foregroundColor: _appleBlue,
                                minimumSize: const Size(0, 44),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () => _openPlayerFromPayload(
                                s.payload,
                                scheduleName: s.name,
                                isManualPreview: true,
                              ),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: const Text(
                                'Putar Offline',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Hapus file offline',
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFFFFF1F0),
                              foregroundColor: const Color(0xFFFF3B30),
                            ),
                            onPressed: () => _deleteOfflineFile(s),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            );
          }),
      ],
    );
  }

  Widget _buildSummaryTab(List<Schedule> activeSchedules) {
    final totalMinutesPerDay = activeSchedules.fold<int>(0, (acc, s) {
      final startTotal = s.startHour * 60 + s.startMinute;
      final endTotal = s.endHour * 60 + s.endMinute;
      final diff = endTotal > startTotal
          ? endTotal - startTotal
          : (24 * 60 - startTotal) + endTotal;
      return acc + diff;
    });
    final totalHours = totalMinutesPerDay ~/ 60;
    final remMinutes = totalMinutesPerDay % 60;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 116),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Setting & Rawat Burung',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1C1C1E),
              ),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _showEditBirdAndCareDialog(isNewCare: false),
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: Text(_birdName),
                ),
                IconButton(
                  tooltip: 'Tambah Profil Burung',
                  onPressed: _showAddBirdProfileDialog,
                  icon: Icon(Icons.add_circle_outline_rounded, color: _appleBlue),
                ),
              ],
            ),
          ],
        ),
        if (_birdProfiles.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _birdProfiles.map((b) {
                final selected = _activeBird.id == b.id;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${b.name} (${b.species})'),
                    selected: selected,
                    selectedColor: _appleBlue,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : const Color(0xFF1C1C1E),
                    ),
                    onSelected: (_) => unawaited(_selectBirdProfile(b.id)),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ['Harian', 'Setting Lomba', 'Mabung', 'Pemulihan'].map((m) {
            final selected = _birdMode == m;
            return ChoiceChip(
              label: Text(m),
              selected: selected,
              selectedColor: _appleBlue,
              labelStyle: TextStyle(
                color: selected ? Colors.white : const Color(0xFF1C1C1E),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              onSelected: (_) => _setBirdMode(m),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE5E5EA)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Checklist Pakan EF & Rawat',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1C1C1E),
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: _resetDailyCare,
                        child: const Text('Reset'),
                      ),
                      TextButton.icon(
                        onPressed: () => _showEditBirdAndCareDialog(isNewCare: true),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Tambah'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...List.generate(_careItems.length, (i) {
                final item = _careItems[i];
                final done = item['done'] == true;
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: done,
                  activeColor: _appleBlue,
                  onChanged: (_) => _toggleCareDone(i),
                  title: Text(
                    item['title']?.toString() ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? const Color(0xFF8E8E93) : const Color(0xFF1C1C1E),
                    ),
                  ),
                  subtitle: Text(
                    item['detail']?.toString() ?? '',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Ringkasan Masteran Harian',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1C1C1E),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _IosMetricCard(
                icon: Icons.alarm_on_rounded,
                iconBg: const Color(0xFFEFF6FF),
                iconColor: _appleBlue,
                label: 'Jadwal Aktif',
                value: '${activeSchedules.length}',
                subtitle: 'dari ${_schedules.length} tersimpan',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IosMetricCard(
                icon: Icons.timelapse_rounded,
                iconBg: const Color(0xFFF0F9FF),
                iconColor: const Color(0xFF0284C7),
                label: 'Durasi Harian',
                value: '${totalHours}j ${remMinutes}m',
                subtitle: 'total jam putar',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE5E5EA)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(8),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt_rounded, color: _appleBlue, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'Putar Cepat Jadwal Aktif',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1C1C1E),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (activeSchedules.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Belum ada jadwal yang diaktifkan. Aktifkan minimal 1 jadwal di tab Jadwal.',
                    style: TextStyle(fontSize: 14, color: Color(0xFF6E6E73)),
                  ),
                )
              else
                ...activeSchedules.map(
                  (s) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F7),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        AnimatedSoundWaveIcon(
                          color: _appleBlue,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              Text(
                                '${s.timeRangeText} · ${s.intervalSummary}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _appleBlue,
                            minimumSize: const Size(0, 38),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => _openPlayerFromPayload(
                            s.payload,
                            scheduleName: s.name,
                            isManualPreview: true,
                          ),
                          child: const Text(
                            'Putar',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccountAndPermissionsTab() {
    final perms = _permStatus;
    final session = ApiService.instance.session;
    final shortDevice = ApiService.instance.deviceId.length > 12
        ? ApiService.instance.deviceId.substring(0, 12)
        : ApiService.instance.deviceId;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 116),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Lisensi Key & Sistem Alarm',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1C1C1E),
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF93C5FD)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(Icons.vpn_key_rounded, color: _appleBlue),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          session?.labelUser ?? 'Pengguna Aktif',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                        Text(
                          'Key: ${session?.key ?? '-'} • HP: $shortDevice... • APK v$_installedAppVersion',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6E6E73),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Auto-Sync Server Aktif • Rev #${_cfg.otaRevision} (tiap ${_cfg.syncIntervalSec}d)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _appleBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEFF6FF),
                        foregroundColor: _appleBlue,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        final ok = await _syncLiveFromServerAndGithub(
                          forceReleaseCheck: true,
                        );
                        if (!mounted || !ok) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Sinkronisasi server & GitHub selesai (Rev #${_cfg.otaRevision})!',
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('Sinkron Server'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF3B30),
                      side: const BorderSide(color: Color(0xFFFFCCC7)),
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _logoutAccount,
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Keluar'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _PermissionStatusCard(
          icon: Icons.memory_rounded,
          title: 'Mesin Alarm Native Android (Wajib)',
          description:
              'Menghubungkan AlarmManager + ForegroundService agar alarm bisa membangunkan HP dan menyalakan video otomatis.',
          granted: _nativeBridgeActive == true,
          accentColor: _appleBlue,
        ),
        _PermissionStatusCard(
          icon: Icons.layers_rounded,
          title: 'Tampil di Atas Aplikasi Lain (Wajib)',
          description:
              'Izin paling penting agar aplikasi bisa otomatis membuka layar video dari latar belakang saat jam alarm tiba.',
          granted: perms?.systemAlertWindowGranted ?? false,
          accentColor: _appleBlue,
          actionLabel: 'Izinkan',
          onAction: _requestOverlayPermission,
        ),
        _PermissionStatusCard(
          icon: Icons.fullscreen_rounded,
          title: 'Notifikasi Layar Penuh (Android 14+)',
          description:
              'Membuka pemutar masteran meski layar HP dalam keadaan terkunci atau mati.',
          granted: perms?.fullScreenIntentGranted ?? true,
          accentColor: _appleBlue,
          actionLabel: 'Buka',
          onAction: _requestFullScreenPermission,
        ),
        _PermissionStatusCard(
          icon: Icons.notifications_active_rounded,
          title: 'Izin Notifikasi Alarm',
          description:
              'Menampilkan status alarm masteran dan pemicu pembukaan jadwal otomatis.',
          granted: perms?.notificationGranted ?? false,
          accentColor: _appleBlue,
        ),
        _PermissionStatusCard(
          icon: Icons.alarm_rounded,
          title: 'Alarm Presisi (Exact AlarmClock)',
          description:
              'Menjaga jadwal berputar tepat waktu setiap hari walaupun HP sedang tidur (Doze Mode).',
          granted: perms?.exactAlarmGranted ?? false,
          accentColor: _appleBlue,
        ),
        _PermissionStatusCard(
          icon: Icons.battery_charging_full_rounded,
          title: 'Abaikan Optimasi Baterai',
          description:
              'Mencegah sistem Android mematikan jadwal otomatis saat aplikasi berada di latar belakang.',
          granted: perms?.batteryOptimizationIgnored ?? false,
          accentColor: _appleBlue,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _appleBlue),
            onPressed: _recheckPermissions,
            icon: const Icon(Icons.verified_user_rounded),
            label: const Text(
              'Periksa & Aktifkan Izin Dasar',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFE5E5EA)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.phone_android_rounded, color: _appleBlue),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Tips Khusus Xiaomi, Oppo, Vivo, Realme & Samsung',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Buka Info Aplikasi -> aktifkan "Mulai Otomatis (Autostart)".\n'
                '2. Pada Penghemat Baterai pilih "Tidak ada pembatasan".\n'
                '3. Kunci (gembok) aplikasi di Recent Apps atau aktifkan "Mode Siaga Malam" di tab Jadwal.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: Color(0xFF3A3A3C),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEFF6FF),
                    foregroundColor: _appleBlue,
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () =>
                      NotifService.instance.openAppDetailsSettings(),
                  icon: const Icon(Icons.settings_rounded, size: 18),
                  label: const Text(
                    'Buka Pengaturan Info Aplikasi',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _socialCategoryLabel(String cat) {
    switch (cat) {
      case 'cuaca':
        return 'Cuaca BMKG';
      case 'rawatan':
        return 'Rawatan';
      case 'isian':
        return 'Isian & Jadwal';
      case 'lomba':
        return 'Info Lomba';
      default:
        return 'Info Umum';
    }
  }

  Color _socialCategoryColor(String cat) {
    switch (cat) {
      case 'cuaca':
        return const Color(0xFF0284C7);
      case 'rawatan':
        return const Color(0xFF059669);
      case 'isian':
        return const Color(0xFF7C3AED);
      case 'lomba':
        return const Color(0xFFD97706);
      default:
        return _appleBlue;
    }
  }

  Widget _buildCommunityTab() {
    if (!_cfg.enableSocialFeed) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 120),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: const Column(
              children: [
                Icon(Icons.forum_outlined, size: 42, color: Color(0xFF8E8E93)),
                SizedBox(height: 12),
                Text(
                  'Tab Komunitas Sedang Dinonaktifkan Admin',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6),
                Text(
                  'Anda masih bisa membagikan info cuaca BMKG dan jadwal masteran langsung ke WhatsApp / Sosmed HP.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF6E6E73)),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final filtered = _socialCategoryFilter == 'all'
        ? _socialPosts
        : _socialPosts
            .where((p) => p.category == _socialCategoryFilter)
            .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [const Color(0xFF0F294D), _appleBlue],
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Komunitas Kicau Mania',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Bagikan info cuaca besok, rawatan gacoan, jadwal masteran & kabar lomba.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE0F2FE),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed:
                        _socialLoading ? null : () => _refreshSocialFeed(),
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                    tooltip: 'Muat ulang feed',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF0F294D),
                        minimumSize: const Size(0, 42),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => _openCreateSocialPostSheet(),
                      icon: const Icon(Icons.edit_note_rounded, size: 19),
                      label: const Text(
                        'Buat Info / Posting',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  if (_bmkgSummary != null) ...[
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withAlpha(36),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 42),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: _socialPosting
                          ? null
                          : () => _shareBmkgToCommunityNow(_bmkgSummary!),
                      icon: const Icon(Icons.cloud_upload_rounded, size: 17),
                      label: const Text(
                        'Info BMKG',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: const [
              MapEntry('all', 'Semua'),
              MapEntry('cuaca', 'Cuaca BMKG'),
              MapEntry('rawatan', 'Rawatan'),
              MapEntry('isian', 'Isian'),
              MapEntry('lomba', 'Lomba'),
              MapEntry('info', 'Info Umum'),
            ].map((entry) {
              final selected = _socialCategoryFilter == entry.key;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(entry.value),
                  selected: selected,
                  selectedColor: _appleBlue,
                  backgroundColor: Colors.white,
                  labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : const Color(0xFF1C1C1E),
                  ),
                  onSelected: (_) {
                    setState(() => _socialCategoryFilter = entry.key);
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        if (_socialLoading && filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE5E5EA)),
            ),
            child: Column(
              children: [
                const Icon(Icons.forum_outlined,
                    size: 40, color: Color(0xFF8E8E93)),
                const SizedBox(height: 10),
                const Text(
                  'Belum ada kiriman pada kategori ini',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Jadilah yang pertama membagikan info cuaca, rawatan, atau masteran hari ini.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _appleBlue),
                  onPressed: () => _openCreateSocialPostSheet(),
                  child: const Text('Bagikan Info Pertama'),
                ),
              ],
            ),
          )
        else
          ...filtered.map((post) {
            final catColor = _socialCategoryColor(post.category);
            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: post.pinned
                      ? const Color(0xFFFCD34D)
                      : const Color(0xFFE5E5EA),
                  width: post.pinned ? 1.5 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(8),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (post.pinned)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Text(
                            'PIN',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF92400E),
                            ),
                          ),
                        ),
                      if (post.isAdmin)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE0F2FE),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Text(
                            'ADMIN',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0369A1),
                            ),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: catColor.withAlpha(24),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          _socialCategoryLabel(post.category),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: catColor,
                          ),
                        ),
                      ),
                      if (post.birdTag.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF2F2F7),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            post.birdTag,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF3A3A3C),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              post.title,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF1C1C1E),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${post.authorName}${post.authorRegion.isNotEmpty ? ' • ${post.authorRegion}' : ''}${post.createdAt.isNotEmpty ? ' • ${SocialService.instance.formatRelativeTime(post.createdAt)}' : ''}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF6E6E73),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (post.isMine)
                        IconButton(
                          tooltip: 'Hapus postingan saya',
                          onPressed: () async {
                            final res = await SocialService.instance
                                .deletePost(post.id);
                            if (!mounted) return;
                            if (res.ok && res.posts != null) {
                              setState(() => _socialPosts = res.posts!);
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(res.message)),
                            );
                          },
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 20,
                            color: Color(0xFFFF3B30),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    post.content,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1C1C1E),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0xFFE5E5EA)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          final res =
                              await SocialService.instance.toggleLike(post.id);
                          if (!mounted) return;
                          if (res.ok && res.post != null) {
                            setState(() {
                              _socialPosts = _socialPosts
                                  .map((p) =>
                                      p.id == res.post!.id ? res.post! : p)
                                  .toList();
                            });
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                post.likedByMe
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                size: 18,
                                color: post.likedByMe
                                    ? const Color(0xFFE11D48)
                                    : const Color(0xFF6E6E73),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '${post.likesCount}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF3A3A3C),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _openSocialCommentsSheet(post),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 17,
                                color: Color(0xFF6E6E73),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '${post.comments.length} Komentar',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF3A3A3C),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF047857),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 34),
                        ),
                        onPressed: () async {
                          final caption = SocialService.instance
                              .buildPostSocialShareCaption(
                            post,
                            appName: _cfg.appName,
                          );
                          final ok = await ApiService.instance.shareToSocial(
                            text: caption,
                            subject: post.title,
                          );
                          if (!ok && mounted) {
                            await Clipboard.setData(
                              ClipboardData(text: caption),
                            );
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Teks postingan disalin ke clipboard.',
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.share_rounded, size: 15),
                        label: const Text(
                          'Share Sosmed',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Future<void> _openCreateSocialPostSheet({
    String initialCategory = 'info',
    String initialTitle = '',
    String initialContent = '',
    String? initialBirdTag,
  }) async {
    String selectedCat = initialCategory;
    final titleCtrl = TextEditingController(text: initialTitle);
    final contentCtrl = TextEditingController(text: initialContent);
    final regionCtrl = TextEditingController(
      text: BmkgWeatherService.instance.regionLabel,
    );
    final birdCtrl = TextEditingController(
      text: initialBirdTag ?? '${_activeBird.name} (${_activeBird.mode})',
    );
    bool alsoShareExternal = false;
    bool sending = false;
    String? errorText;

    final created = await showModalBottomSheet<SocialPost?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bagikan Info ke Komunitas',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: const [
                        MapEntry('info', 'Info Umum'),
                        MapEntry('cuaca', 'Cuaca BMKG'),
                        MapEntry('rawatan', 'Rawatan'),
                        MapEntry('isian', 'Isian'),
                        MapEntry('lomba', 'Lomba'),
                      ].map((e) {
                        final active = selectedCat == e.key;
                        return ChoiceChip(
                          label: Text(e.value),
                          selected: active,
                          selectedColor: _appleBlue,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? Colors.white
                                : const Color(0xFF1C1C1E),
                          ),
                          onSelected: (_) {
                            setSheetState(() => selectedCat = e.key);
                          },
                        );
                      }).toList(),
                    ),
                    if (_bmkgSummary != null) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _appleBlue,
                          side: const BorderSide(color: Color(0xFF93C5FD)),
                          minimumSize: const Size(0, 34),
                        ),
                        onPressed: () {
                          final s = _bmkgSummary!;
                          setSheetState(() {
                            selectedCat = 'cuaca';
                            titleCtrl.text =
                                SocialService.instance.buildBmkgShareTitle(s);
                            contentCtrl.text =
                                SocialService.instance.buildBmkgShareBody(s);
                            regionCtrl.text = s.regionLabel;
                          });
                        },
                        icon: const Icon(Icons.wb_sunny_rounded, size: 15),
                        label: const Text(
                          'Isi Otomatis Info Cuaca BMKG Besok',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleCtrl,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Judul Info',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: regionCtrl,
                            maxLength: 80,
                            decoration: const InputDecoration(
                              labelText: 'Wilayah / Kota',
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: birdCtrl,
                            maxLength: 60,
                            decoration: const InputDecoration(
                              labelText: 'Gacoan / Tag',
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: contentCtrl,
                      maxLines: 4,
                      maxLength: 800,
                      decoration: const InputDecoration(
                        labelText: 'Isi Informasi / Tips / Kondisi Wilayah',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: alsoShareExternal,
                      activeColor: _appleBlue,
                      title: const Text(
                        'Sekaligus bagikan ke WhatsApp / Facebook / Sosmed HP',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onChanged: (v) {
                        setSheetState(() => alsoShareExternal = v ?? false);
                      },
                    ),
                    if (errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          errorText!,
                          style: const TextStyle(
                            color: Color(0xFFFF3B30),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: _appleBlue,
                          minimumSize: const Size(0, 46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: sending
                            ? null
                            : () async {
                                final t = titleCtrl.text.trim();
                                final c = contentCtrl.text.trim();
                                if (t.isEmpty || c.isEmpty) {
                                  setSheetState(() {
                                    errorText =
                                        'Judul dan isi informasi tidak boleh kosong.';
                                  });
                                  return;
                                }
                                setSheetState(() {
                                  sending = true;
                                  errorText = null;
                                });
                                final res =
                                    await SocialService.instance.createPost(
                                  category: selectedCat,
                                  title: t,
                                  content: c,
                                  authorRegion: regionCtrl.text.trim(),
                                  birdTag: birdCtrl.text.trim(),
                                );
                                if (!ctx.mounted) return;
                                if (res.ok && res.post != null) {
                                  if (alsoShareExternal) {
                                    final cap = SocialService.instance
                                        .buildPostSocialShareCaption(
                                      res.post!,
                                      appName: _cfg.appName,
                                    );
                                    unawaited(
                                      ApiService.instance.shareToSocial(
                                        text: cap,
                                        subject: res.post!.title,
                                      ),
                                    );
                                  }
                                  Navigator.of(ctx).pop(res.post);
                                } else {
                                  setSheetState(() {
                                    sending = false;
                                    errorText = res.message;
                                  });
                                }
                              },
                        icon: const Icon(Icons.send_rounded, size: 17),
                        label: Text(
                          sending ? 'Mengirim...' : 'Terbitkan Sekarang',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (created != null && mounted) {
      await _refreshSocialFeed();
      if (!mounted) return;
      setState(() => _activeTabIndex = 2);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Info berhasil diterbitkan ke Komunitas!'),
        ),
      );
    }
  }

  Future<void> _openSocialCommentsSheet(SocialPost initialPost) async {
    SocialPost currentPost = initialPost;
    final cmtCtrl = TextEditingController();
    bool sending = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentPost.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (currentPost.comments.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Belum ada komentar. Mulai diskusi kicau mania di bawah!',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6E6E73),
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: currentPost.comments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, idx) {
                          final c = currentPost.comments[idx];
                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.authorName,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  c.content,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF334155),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: cmtCtrl,
                          maxLength: 300,
                          decoration: const InputDecoration(
                            hintText: 'Tulis komentar...',
                            border: OutlineInputBorder(),
                            counterText: '',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _appleBlue,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: sending
                            ? null
                            : () async {
                                final text = cmtCtrl.text.trim();
                                if (text.isEmpty) return;
                                setSheetState(() => sending = true);
                                final res =
                                    await SocialService.instance.addComment(
                                  postId: currentPost.id,
                                  content: text,
                                );
                                if (!ctx.mounted) return;
                                if (res.ok && res.post != null) {
                                  cmtCtrl.clear();
                                  setSheetState(() {
                                    currentPost = res.post!;
                                    sending = false;
                                  });
                                  if (mounted) {
                                    setState(() {
                                      _socialPosts = _socialPosts
                                          .map((p) => p.id == res.post!.id
                                              ? res.post!
                                              : p)
                                          .toList();
                                    });
                                  }
                                } else {
                                  setSheetState(() => sending = false);
                                }
                              },
                        child: const Icon(Icons.send_rounded, size: 18),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openShareScheduleSheet(
    Schedule schedule, {
    String? birdLabel,
  }) async {
    final resolvedBird =
        (birdLabel != null && birdLabel.isNotEmpty) ? birdLabel : _activeBird.name;
    final caption = SocialService.instance.buildScheduleSocialShareCaption(
      schedule,
      birdLabel: resolvedBird,
      appName: _cfg.appName,
    );

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bagikan: ${schedule.name}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Pilih saluran untuk membagikan info jadwal & setelan masteran ini.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              if (_cfg.enableSocialFeed)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEFF6FF),
                    child: Icon(Icons.forum_rounded, color: _appleBlue),
                  ),
                  title: const Text(
                    'Pos ke Komunitas Aplikasi',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Tampil untuk sesama pengguna APK Mendek Arena',
                    style: TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _openCreateSocialPostSheet(
                      initialCategory: 'isian',
                      initialTitle: SocialService.instance
                          .buildScheduleShareTitle(schedule, birdLabel: resolvedBird),
                      initialContent: SocialService.instance
                          .buildScheduleShareBody(schedule, birdLabel: resolvedBird),
                      initialBirdTag: resolvedBird,
                    );
                  },
                ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFECFDF5),
                  child: Icon(Icons.share_rounded, color: Color(0xFF047857)),
                ),
                title: const Text(
                  'Bagikan ke WhatsApp / Facebook / Sosmed',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'Buka pemilih aplikasi media sosial di HP Anda',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  final ok = await ApiService.instance.shareToSocial(
                    text: caption,
                    subject: schedule.name,
                  );
                  if (!ok && mounted) {
                    await Clipboard.setData(ClipboardData(text: caption));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Teks disalin ke clipboard.')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFF2F2F7),
                  child: Icon(Icons.copy_rounded, color: Color(0xFF1C1C1E)),
                ),
                title: const Text(
                  'Salin Teks Caption',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'Tempel manual ke TikTok, IG, atau status WA',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await Clipboard.setData(ClipboardData(text: caption));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Caption info masteran disalin ke clipboard.'),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _IosBottomMenuBar extends StatelessWidget {
  final int activeIndex;
  final int activeCount;
  final int offlineCount;
  final int socialCount;
  final bool allPermissionsGranted;
  final Color accentColor;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onAddTap;

  const _IosBottomMenuBar({
    required this.activeIndex,
    required this.activeCount,
    required this.offlineCount,
    required this.socialCount,
    required this.allPermissionsGranted,
    required this.accentColor,
    required this.onSelectTab,
    required this.onAddTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(235),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFFD1D1D6)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.calendar_month_rounded,
                      label: 'Jadwal',
                      badgeText: activeCount > 0 ? '$activeCount' : null,
                      selected: activeIndex == 0,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(0),
                    ),
                  ),
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.offline_pin_rounded,
                      label: 'Offline',
                      badgeText: offlineCount > 0 ? '$offlineCount' : null,
                      selected: activeIndex == 1,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(1),
                    ),
                  ),
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.forum_rounded,
                      label: 'Sosial',
                      badgeText: socialCount > 0 ? '$socialCount' : null,
                      selected: activeIndex == 2,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(2),
                    ),
                  ),
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.tune_rounded,
                      label: 'Setting',
                      selected: activeIndex == 3,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(3),
                    ),
                  ),
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.verified_user_rounded,
                      label: 'Akun',
                      showWarningDot: !allPermissionsGranted,
                      selected: activeIndex == 4,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(4),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Material(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: onAddTap,
                      borderRadius: BorderRadius.circular(20),
                      child: const SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.add_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuBarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? badgeText;
  final bool showWarningDot;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  const _MenuBarItem({
    required this.icon,
    required this.label,
    this.badgeText,
    this.showWarningDot = false,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEFF6FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: selected ? accentColor : const Color(0xFF8E8E93),
                ),
                if (badgeText != null)
                  Positioned(
                    right: -10,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: accentColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badgeText!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                if (showWarningDot)
                  Positioned(
                    right: -3,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF9500),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? accentColor : const Color(0xFF8E8E93),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosMetricCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;
  final String subtitle;

  const _IosMetricCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE5E5EA)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6E6E73),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1C1C1E),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
          ),
        ],
      ),
    );
  }
}

class _PermissionStatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool granted;
  final Color accentColor;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _PermissionStatusCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    required this.accentColor,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: granted ? const Color(0xFF93C5FD) : const Color(0xFFE5E5EA),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: granted
                  ? const Color(0xFFEFF6FF)
                  : const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              icon,
              color: granted ? accentColor : const Color(0xFFB45309),
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: granted
                            ? const Color(0xFFEFF6FF)
                            : const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        granted ? 'Aktif' : 'Perlu Izin',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: granted
                              ? accentColor
                              : const Color(0xFFB45309),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6E6E73),
                  ),
                ),
                if (!granted && actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFEFF6FF),
                      foregroundColor: accentColor,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: onAction,
                    child: Text(
                      actionLabel!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  static const List<MapEntry<int, String>> _shortDays = [
    MapEntry(1, 'S'),
    MapEntry(2, 'S'),
    MapEntry(3, 'R'),
    MapEntry(4, 'K'),
    MapEntry(5, 'J'),
    MapEntry(6, 'S'),
    MapEntry(7, 'M'),
  ];

  final Schedule schedule;
  final String? birdLabel;
  final Color accentColor;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPlayNow;
  final VoidCallback onTestAlarm;
  final VoidCallback onShare;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ScheduleCard({
    required this.schedule,
    this.birdLabel,
    required this.accentColor,
    required this.onToggle,
    required this.onPlayNow,
    required this.onTestAlarm,
    required this.onShare,
    required this.onEdit,
    required this.onDelete,
  });

  String _durationLabel() {
    final startMin = schedule.startHour * 60 + schedule.startMinute;
    final endMin = schedule.endHour * 60 + schedule.endMinute;
    final diff = endMin > startMin
        ? endMin - startMin
        : (24 * 60 - startMin) + endMin;
    final h = diff ~/ 60;
    final m = diff % 60;
    if (m == 0) return '${h}j';
    return '${h}j ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final isYt = schedule.platform == 'youtube';
    final isLocal = schedule.platform == 'local';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: schedule.isActive
              ? const Color(0xFF93C5FD)
              : const Color(0xFFE5E5EA),
          width: schedule.isActive ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: schedule.isActive
                ? accentColor.withAlpha(24)
                : Colors.black.withAlpha(8),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: isYt
                        ? const Color(0xFFFFF1F0)
                        : const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isYt
                          ? const Color(0xFFFFD6D2)
                          : const Color(0xFFE5E5EA),
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      isYt
                          ? Icons.play_circle_filled_rounded
                          : (isLocal
                              ? Icons.audio_file_rounded
                              : Icons.music_note_rounded),
                      color: isYt
                          ? const Color(0xFFFF3B30)
                          : (isLocal
                              ? accentColor
                              : const Color(0xFF1C1C1E)),
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        schedule.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: schedule.isActive
                                  ? const Color(0xFFEFF6FF)
                                  : const Color(0xFFF2F2F7),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (schedule.isActive) ...[
                                  AnimatedSoundWaveIcon(
                                    color: accentColor,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Text(
                                  schedule.isActive ? 'AKTIF' : 'NONAKTIF',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: schedule.isActive
                                        ? accentColor
                                        : const Color(0xFF8E8E93),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (schedule.isOfflineReady)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2FE),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'OFFLINE',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0369A1),
                                ),
                              ),
                            ),
                          if (schedule.effectiveTracks.length > 1)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFECFDF5),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${schedule.effectiveTracks.length} Track',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF047857),
                                ),
                              ),
                            ),
                          if (schedule.ambientTherapy != 'none')
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0FDF4),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                schedule.ambientLabel,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF15803D),
                                ),
                              ),
                            ),
                          if (birdLabel != null && birdLabel!.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                birdLabel!,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF374151),
                                ),
                              ),
                            ),
                          Text(
                            schedule.platformLabel,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6E6E73),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                CupertinoSwitch(
                  value: schedule.isActive,
                  activeColor: accentColor,
                  onChanged: onToggle,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: schedule.isActive
                    ? const Color(0xFFF4F8FF)
                    : const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: schedule.isActive
                      ? const Color(0xFFDBEAFE)
                      : const Color(0xFFE5E5EA),
                ),
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'MULAI',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6E6E73),
                          letterSpacing: 0.4,
                        ),
                      ),
                      Text(
                        schedule.formattedStartTime,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: schedule.isActive
                              ? accentColor
                              : const Color(0xFF6E6E73),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFE5E5EA),
                            ),
                          ),
                          child: Text(
                            _durationLabel(),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF3A3A3C),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: Color(0xFFCBD5E1),
                                thickness: 1.5,
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 14,
                              color: Color(0xFF94A3B8),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'SELESAI',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6E6E73),
                          letterSpacing: 0.4,
                        ),
                      ),
                      Text(
                        schedule.formattedEndTime,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: schedule.isActive
                              ? const Color(0xFF1C1C1E)
                              : const Color(0xFF6E6E73),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: _shortDays.map((dayEntry) {
                      final activeDay = schedule.days.contains(dayEntry.key);
                      return Container(
                        width: 24,
                        height: 24,
                        margin: const EdgeInsets.only(right: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: activeDay
                              ? (schedule.isActive
                                  ? accentColor
                                  : const Color(0xFF8E8E93))
                              : const Color(0xFFF2F2F7),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          dayEntry.value,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: activeDay
                                ? Colors.white
                                : const Color(0xFF8E8E93),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timelapse_rounded,
                        size: 14,
                        color: accentColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        schedule.hasInterval
                            ? '${schedule.playMinutes}m / ${schedule.pauseMinutes}m'
                            : 'Nonstop',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1D4ED8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFEFF6FF),
                      foregroundColor: accentColor,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: onPlayNow,
                    icon: const Icon(Icons.play_arrow_rounded, size: 22),
                    label: Text(
                      schedule.isOfflineReady ? 'Putar Offline' : 'Putar',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    backgroundColor: const Color(0xFFF4F8FF),
                    side: const BorderSide(color: Color(0xFFDBEAFE)),
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: onTestAlarm,
                  icon: const Icon(Icons.alarm_add_rounded, size: 17),
                  label: const Text(
                    'Tes',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 40,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconButton(
                    tooltip: 'Bagikan info jadwal',
                    padding: EdgeInsets.zero,
                    onPressed: onShare,
                    icon: const Icon(
                      Icons.share_rounded,
                      color: Color(0xFF047857),
                      size: 19,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 40,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F2F7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconButton(
                    tooltip: 'Edit jadwal',
                    padding: EdgeInsets.zero,
                    onPressed: onEdit,
                    icon: const Icon(
                      Icons.edit_rounded,
                      color: Color(0xFF1C1C1E),
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 40,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF1F0),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconButton(
                    tooltip: 'Hapus jadwal',
                    padding: EdgeInsets.zero,
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFFF3B30),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
