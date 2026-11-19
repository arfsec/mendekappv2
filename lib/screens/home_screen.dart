import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/schedule.dart';
import '../services/api_service.dart';
import '../services/db_service.dart';
import '../services/notif_service.dart';
import '../services/offline_service.dart';
import '../widgets/premium_visuals.dart';
import 'add_edit_screen.dart';
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

  List<Schedule> _schedules = [];
  bool _isLoading = true;
  PermissionStatusSummary? _permStatus;
  StreamSubscription<String>? _notifSub;
  Timer? _clockWatcherTimer;
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
    final schedules = await _syncLocalOfflinePaths(
      await DbService.instance.getAllSchedules(),
    );
    await NotifService.instance.rescheduleAll(schedules);

    PermissionStatusSummary perms;
    if (widget.initialPayload == null || widget.initialPayload!.isEmpty) {
      perms = await NotifService.instance.requestRequiredPermissions();
    } else {
      perms = await NotifService.instance.checkPermissions();
    }

    if (!mounted) return;
    setState(() {
      _nightStandbyMode = savedStandby;
      _permStatus = perms;
      _nativeBridgeActive = bridgeOk;
      _schedules = schedules;
      _clockNow = DateTime.now();
      _isLoading = false;
    });

    _checkActiveScheduleNow();
    unawaited(_checkLicenseInBackground());
  }

  Future<void> _checkLicenseInBackground() async {
    // Revalidasi key di latar belakang agar blokir/hapus key dari server langsung berlaku
    final stillValid = await ApiService.instance.revalidateInBackground();
    if (!mounted) return;
    if (!stillValid) {
      Navigator.of(context).pushReplacement(
        buildPremiumRoute(LoginScreen(pendingPayload: widget.initialPayload)),
      );
    }
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
    final schedules = await _syncLocalOfflinePaths(
      await DbService.instance.getAllSchedules(),
    );
    if (mounted) {
      setState(() {
        _schedules = schedules;
        _clockNow = DateTime.now();
      });
      _checkActiveScheduleNow();
    }
  }

  Future<void> _openPlayerFromPayload(
    String payload, {
    String? scheduleName,
    bool isManualPreview = false,
  }) async {
    if (!mounted || _isPlayerOpen) return;

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
    unawaited(NotifService.instance.clearActiveAlarmNotification());

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

  Future<void> _openAddEdit([Schedule? schedule]) async {
    final saved = await Navigator.of(context).push<bool>(
      buildPremiumRoute(AddEditScreen(existingSchedule: schedule)),
    );
    if (saved == true) {
      if (schedule != null) {
        _triggeredScheduleKeys.removeWhere(
          (k) => k.startsWith('${schedule.id}_'),
        );
      }
      await _reloadSchedules();
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
                        child: const Icon(
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
                        onTap: () => setState(() => _activeTabIndex = 3),
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
        allPermissionsGranted: _permStatus?.allGranted == true,
        accentColor: _appleBlue,
        onSelectTab: (idx) => setState(() => _activeTabIndex = idx),
        onAddTap: () => _openAddEdit(),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: _appleBlue))
          : RefreshIndicator(
              color: _appleBlue,
              onRefresh: _reloadSchedules,
              child: _activeTabIndex == 0
                  ? _buildSchedulesTab(activeSchedules, activeCount)
                  : _activeTabIndex == 1
                      ? _buildOfflineTab()
                      : _activeTabIndex == 2
                          ? _buildSummaryTab(activeSchedules)
                          : _buildAccountAndPermissionsTab(),
            ),
    );
  }

  Widget _buildSchedulesTab(List<Schedule> activeSchedules, int activeCount) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 116),
      children: [
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
                        onPressed: () => setState(() => _activeTabIndex = 3),
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
        if (_schedules.isEmpty)
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
          ..._schedules.map(
            (schedule) => _ScheduleCard(
              schedule: schedule,
              accentColor: _appleBlue,
              onToggle: (val) => _toggleSchedule(schedule, val),
              onPlayNow: () => _openPlayerFromPayload(
                schedule.payload,
                scheduleName: schedule.name,
                isManualPreview: true,
              ),
              onTestAlarm: () => _triggerTestAlarm(schedule),
              onEdit: () => _openAddEdit(schedule),
              onDelete: () => _deleteSchedule(schedule),
            ),
          ),
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
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            'Ringkasan Masteran Harian',
            style: TextStyle(
              fontSize: 22,
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
                          'Key: ${session?.key ?? '-'} • HP: $shortDevice...',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6E6E73),
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
                        final ok = await ApiService.instance
                            .revalidateInBackground();
                        if (!mounted) return;
                        if (!ok) {
                          Navigator.of(context).pushReplacement(
                            buildPremiumRoute(const LoginScreen()),
                          );
                          return;
                        }
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Tema, fitur, & status key berhasil disinkronkan!',
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
}

class _IosBottomMenuBar extends StatelessWidget {
  final int activeIndex;
  final int activeCount;
  final int offlineCount;
  final bool allPermissionsGranted;
  final Color accentColor;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onAddTap;

  const _IosBottomMenuBar({
    required this.activeIndex,
    required this.activeCount,
    required this.offlineCount,
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
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                      icon: Icons.bar_chart_rounded,
                      label: 'Ringkasan',
                      selected: activeIndex == 2,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(2),
                    ),
                  ),
                  Expanded(
                    child: _MenuBarItem(
                      icon: Icons.verified_user_rounded,
                      label: 'Akun',
                      showWarningDot: !allPermissionsGranted,
                      selected: activeIndex == 3,
                      accentColor: accentColor,
                      onTap: () => onSelectTab(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Material(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(22),
                    child: InkWell(
                      onTap: onAddTap,
                      borderRadius: BorderRadius.circular(22),
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.add_rounded,
                          color: Colors.white,
                          size: 26,
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
  final Color accentColor;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPlayNow;
  final VoidCallback onTestAlarm;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ScheduleCard({
    required this.schedule,
    required this.accentColor,
    required this.onToggle,
    required this.onPlayNow,
    required this.onTestAlarm,
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
                          : Icons.music_note_rounded,
                      color: isYt
                          ? const Color(0xFFFF3B30)
                          : const Color(0xFF1C1C1E),
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
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    backgroundColor: const Color(0xFFF4F8FF),
                    side: const BorderSide(color: Color(0xFFDBEAFE)),
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: onTestAlarm,
                  icon: const Icon(Icons.alarm_add_rounded, size: 18),
                  label: const Text(
                    'Tes 10d',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1C1C1E),
                    backgroundColor: const Color(0xFFF2F2F7),
                    side: BorderSide.none,
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: onEdit,
                  child: const Icon(Icons.edit_rounded, size: 18),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF1F0),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: IconButton(
                    tooltip: 'Hapus jadwal',
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFFF3B30),
                      size: 22,
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
