import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class LiveModuleItem {
  final String id;
  final String title;
  final String subtitle;
  final String url;
  final String badge;
  final String openMode;
  final bool enabled;

  const LiveModuleItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    required this.url,
    this.badge = 'LIVE',
    this.openMode = 'webview',
    this.enabled = true,
  });

  factory LiveModuleItem.fromJson(Map<String, dynamic> json) {
    final rawUrl = ((json['url'] as String?) ?? '').trim();
    return LiveModuleItem(
      id: ((json['id'] as String?) ?? '').trim(),
      title: ((json['title'] as String?) ?? 'Fitur Live').trim(),
      subtitle: ((json['subtitle'] as String?) ?? '').trim(),
      url: rawUrl,
      badge: ((json['badge'] as String?) ?? 'LIVE').trim().isNotEmpty
          ? ((json['badge'] as String?) ?? 'LIVE').trim()
          : 'LIVE',
      openMode: ((json['open_mode'] as String?) ?? 'webview').trim() == 'external'
          ? 'external'
          : 'webview',
      enabled: json['enabled'] == null
          ? true
          : json['enabled'] == true ||
              json['enabled'] == 1 ||
              json['enabled'] == '1' ||
              json['enabled'] == 'true',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'url': url,
        'badge': badge,
        'open_mode': openMode,
        'enabled': enabled,
      };
}

class ApkInstallResult {
  final bool started;
  final bool needsPermission;
  final String message;

  const ApkInstallResult({
    required this.started,
    this.needsPermission = false,
    this.message = '',
  });
}

class RemoteConfig {
  final String appName;
  final String logoUrl;
  final int fadeInDefaultSec;
  final String accentColorHex;
  final String heroTitle;
  final String heroSubtitle;
  final String announcement;
  final String waNumber;
  final String waMessage;
  final String tiktokUrl;
  final bool enableOfflineDownload;
  final bool enableCloudAnim;
  final bool enableSocialFeed;
  final String minVersion;
  final int batteryGuardDefaultPct;
  final int batteryGuardMaxTempC;
  final String apkDownloadUrl;
  final String githubSyncUrl;
  final String githubRepo;
  final int syncIntervalSec;
  final int otaRevision;
  final List<LiveModuleItem> liveModules;

  const RemoteConfig({
    this.appName = 'Mendek Arena',
    this.logoUrl = '',
    this.fadeInDefaultSec = 25,
    this.accentColorHex = '#007AFF',
    this.heroTitle = 'Masteran Burung Otomatis',
    this.heroSubtitle = 'Jadwal Harian, Offline & Anti Layar Mati',
    this.announcement = '',
    this.waNumber = '6281234567890',
    this.waMessage =
        'Halo Admin, saya ingin meminta Key Login Mendek Arena Masteran Burung.',
    this.tiktokUrl = 'https://www.tiktok.com/@mendekarena',
    this.enableOfflineDownload = true,
    this.enableCloudAnim = true,
    this.enableSocialFeed = true,
    this.minVersion = '1.0.0',
    this.batteryGuardDefaultPct = 90,
    this.batteryGuardMaxTempC = 42,
    this.apkDownloadUrl = '',
    this.githubSyncUrl = '',
    this.githubRepo = '',
    this.syncIntervalSec = 90,
    this.otaRevision = 1,
    this.liveModules = const [],
  });

  Color get accentColor {
    try {
      final cleaned = accentColorHex.replaceAll('#', '').trim();
      if (cleaned.length == 6) {
        return Color(int.parse('FF$cleaned', radix: 16));
      }
      if (cleaned.length == 8) {
        return Color(int.parse(cleaned, radix: 16));
      }
    } catch (_) {}
    return const Color(0xFF007AFF);
  }

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    return RemoteConfig(
      appName: ((json['app_name'] as String?) ?? '').trim().isNotEmpty
          ? (json['app_name'] as String).trim()
          : 'Mendek Arena',
      logoUrl: ((json['logo_url'] as String?) ?? '').trim(),
      fadeInDefaultSec:
          int.tryParse('${json['fade_in_default_sec'] ?? 25}') ?? 25,
      accentColorHex: (json['accent_color'] as String?) ?? '#007AFF',
      heroTitle:
          (json['hero_title'] as String?) ?? 'Masteran Burung Otomatis',
      heroSubtitle: (json['hero_subtitle'] as String?) ??
          'Jadwal Harian, Offline & Anti Layar Mati',
      announcement: (json['announcement'] as String?) ?? '',
      waNumber: (json['wa_number'] as String?) ?? '6281234567890',
      waMessage: (json['wa_message'] as String?) ??
          'Halo Admin, saya ingin meminta Key Login Mendek Arena Masteran Burung.',
      tiktokUrl: (json['tiktok_url'] as String?) ??
          'https://www.tiktok.com/@mendekarena',
      enableOfflineDownload: json['enable_offline_download'] == null
          ? true
          : json['enable_offline_download'] == true ||
              json['enable_offline_download'] == 1 ||
              json['enable_offline_download'] == '1',
      enableCloudAnim: json['enable_cloud_anim'] == null
          ? true
          : json['enable_cloud_anim'] == true ||
              json['enable_cloud_anim'] == 1 ||
              json['enable_cloud_anim'] == '1',
      enableSocialFeed: json['enable_social_feed'] == null
          ? true
          : json['enable_social_feed'] == true ||
              json['enable_social_feed'] == 1 ||
              json['enable_social_feed'] == '1',
      minVersion: (json['min_version'] as String?) ?? '1.0.0',
      batteryGuardDefaultPct:
          (int.tryParse('${json['battery_guard_default_pct'] ?? 90}') ?? 90)
              .clamp(50, 100),
      batteryGuardMaxTempC:
          (int.tryParse('${json['battery_guard_max_temp_c'] ?? 42}') ?? 42)
              .clamp(35, 55),
      apkDownloadUrl: ((json['apk_download_url'] as String?) ?? '').trim(),
      githubSyncUrl: ((json['github_sync_url'] as String?) ?? '').trim(),
      githubRepo: ((json['github_repo'] as String?) ?? '').trim(),
      syncIntervalSec:
          (int.tryParse('${json['sync_interval_sec'] ?? 90}') ?? 90)
              .clamp(30, 600),
      otaRevision:
          (int.tryParse('${json['ota_revision'] ?? 1}') ?? 1).clamp(1, 999999),
      liveModules: (json['live_modules'] is List)
          ? (json['live_modules'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(LiveModuleItem.fromJson)
              .where((m) =>
                  m.title.isNotEmpty &&
                  m.url.toLowerCase().startsWith('https://'))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'app_name': appName,
        'logo_url': logoUrl,
        'fade_in_default_sec': fadeInDefaultSec,
        'accent_color': accentColorHex,
        'hero_title': heroTitle,
        'hero_subtitle': heroSubtitle,
        'announcement': announcement,
        'wa_number': waNumber,
        'wa_message': waMessage,
        'tiktok_url': tiktokUrl,
        'enable_offline_download': enableOfflineDownload,
        'enable_cloud_anim': enableCloudAnim,
        'enable_social_feed': enableSocialFeed,
        'min_version': minVersion,
        'battery_guard_default_pct': batteryGuardDefaultPct,
        'battery_guard_max_temp_c': batteryGuardMaxTempC,
        'apk_download_url': apkDownloadUrl,
        'github_sync_url': githubSyncUrl,
        'github_repo': githubRepo,
        'sync_interval_sec': syncIntervalSec,
        'ota_revision': otaRevision,
        'live_modules': liveModules.map((m) => m.toJson()).toList(),
      };
}

class BatterySnapshotData {
  final int levelPct;
  final bool isCharging;
  final double tempCelsius;

  const BatterySnapshotData({
    required this.levelPct,
    required this.isCharging,
    required this.tempCelsius,
  });
}

class PickedLocalMedia {
  final String path;
  final String name;
  final bool isAudioOnly;

  const PickedLocalMedia({
    required this.path,
    required this.name,
    required this.isAudioOnly,
  });
}

class LicenseSession {
  final String key;
  final String labelUser;
  final String? expiresAt;
  final String boundDeviceId;
  final String musicBoxKey;
  final String musicBoxDeviceId;
  final String musicBoxName;
  final String? musicBoxSyncedAt;

  const LicenseSession({
    required this.key,
    required this.labelUser,
    this.expiresAt,
    required this.boundDeviceId,
    this.musicBoxKey = '',
    this.musicBoxDeviceId = '',
    this.musicBoxName = '',
    this.musicBoxSyncedAt,
  });

  LicenseSession copyWith({
    String? labelUser,
    String? expiresAt,
    bool clearExpiresAt = false,
    String? musicBoxKey,
    String? musicBoxDeviceId,
    String? musicBoxName,
    String? musicBoxSyncedAt,
  }) {
    return LicenseSession(
      key: key,
      labelUser: labelUser ?? this.labelUser,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      boundDeviceId: boundDeviceId,
      musicBoxKey: musicBoxKey ?? this.musicBoxKey,
      musicBoxDeviceId: musicBoxDeviceId ?? this.musicBoxDeviceId,
      musicBoxName: musicBoxName ?? this.musicBoxName,
      musicBoxSyncedAt: musicBoxSyncedAt ?? this.musicBoxSyncedAt,
    );
  }

  factory LicenseSession.fromJson(Map<String, dynamic> json) {
    return LicenseSession(
      key: (json['key'] as String?) ?? '',
      labelUser: (json['label_user'] as String?) ?? 'Kicau Mania',
      expiresAt: json['expires_at'] as String?,
      boundDeviceId: (json['bound_device_id'] as String?) ?? '',
      musicBoxKey: (json['music_box_key'] as String?) ?? '',
      musicBoxDeviceId: (json['music_box_device_id'] as String?) ?? '',
      musicBoxName: (json['music_box_name'] as String?) ?? '',
      musicBoxSyncedAt: json['music_box_synced_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label_user': labelUser,
        'expires_at': expiresAt,
        'bound_device_id': boundDeviceId,
        'music_box_key': musicBoxKey,
        'music_box_device_id': musicBoxDeviceId,
        'music_box_name': musicBoxName,
        'music_box_synced_at': musicBoxSyncedAt,
      };
}

class CatalogPreset {
  final String id;
  final String title;
  final String species;
  final String platform;
  final String url;
  final int recommendedPlayMin;
  final int recommendedPauseMin;
  final int recommendedFadeSec;

  const CatalogPreset({
    required this.id,
    required this.title,
    required this.species,
    required this.platform,
    required this.url,
    this.recommendedPlayMin = 15,
    this.recommendedPauseMin = 5,
    this.recommendedFadeSec = 25,
  });

  factory CatalogPreset.fromJson(Map<String, dynamic> json) {
    return CatalogPreset(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Masteran Rekomendasi',
      species: (json['species'] as String?) ?? 'Semua Burung Kicau',
      platform: ((json['platform'] as String?) ?? 'youtube').toLowerCase(),
      url: (json['url'] as String?) ?? '',
      recommendedPlayMin:
          int.tryParse('${json['recommended_play_min'] ?? 15}') ?? 15,
      recommendedPauseMin:
          int.tryParse('${json['recommended_pause_min'] ?? 5}') ?? 5,
      recommendedFadeSec:
          int.tryParse('${json['recommended_fade_sec'] ?? 25}') ?? 25,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'species': species,
        'platform': platform,
        'url': url,
        'recommended_play_min': recommendedPlayMin,
        'recommended_pause_min': recommendedPauseMin,
        'recommended_fade_sec': recommendedFadeSec,
      };
}

class VerifyResult {
  final bool ok;
  final String message;

  const VerifyResult({required this.ok, required this.message});
}

class ApiService {
  ApiService._();
  static final ApiService instance = ApiService._();

  static const String baseUrl = 'https://limopancer.com/mendek/api.php';
  static const String appVersion = '3.3.0';

  static const String _prefDeviceId = 'mendek_device_id_v1';
  static const String _prefSession = 'mendek_license_session_v1';
  static const String _prefRemoteConfig = 'mendek_remote_config_v1';
  static const String _prefCatalog = 'mendek_catalog_v1';
  static const MethodChannel _alarmChannel =
      MethodChannel('com.mendekarena.mendek_arena_masteran/alarm');

  SharedPreferences? _prefs;
  String _deviceId = '';
  LicenseSession? _session;
  RemoteConfig _remoteConfig = const RemoteConfig();
  List<CatalogPreset> _catalog = const [];
  String _latestGithubVersion = '';
  String _latestGithubApkUrl = '';
  DateTime? _lastGithubReleaseCheck;
  DateTime? _lastSyncedAt;

  String get deviceId => _deviceId;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String get effectiveUpdateVersion {
    if (_remoteConfig.apkDownloadUrl.startsWith('https://') &&
        _remoteConfig.minVersion.trim().isNotEmpty) {
      return _remoteConfig.minVersion.trim();
    }
    if (_latestGithubApkUrl.startsWith('https://') &&
        _latestGithubVersion.isNotEmpty) {
      return _latestGithubVersion;
    }
    return _remoteConfig.minVersion.trim();
  }

  String get effectiveApkDownloadUrl {
    final direct = _remoteConfig.apkDownloadUrl.trim();
    if (direct.startsWith('https://')) return direct;
    if (_latestGithubApkUrl.startsWith('https://')) return _latestGithubApkUrl;
    return direct;
  }
  String? lastAuthError;

  LicenseSession? get session => _session;
  RemoteConfig get remoteConfig => _remoteConfig;
  List<CatalogPreset> get catalog => _catalog;

  DateTime? get expiresAtDate {
    final raw = _session?.expiresAt?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  bool get isSessionExpired {
    final d = expiresAtDate;
    if (d == null) return false;
    return DateTime.now().isAfter(d);
  }

  int? get remainingDaysLeft {
    final d = expiresAtDate;
    if (d == null) return null;
    final diffHours = d.difference(DateTime.now()).inHours;
    if (diffHours <= 0) return 0;
    return (diffHours / 24).ceil();
  }

  String get expiryDisplayLabel {
    final raw = _session?.expiresAt?.trim();
    if (raw == null || raw.isEmpty) return 'Selamanya (Lifetime)';
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  bool get hasValidSession =>
      _session != null && _session!.key.isNotEmpty && !isSessionExpired;

  String get _deviceLabel {
    if (Platform.isAndroid) return 'Android HP';
    if (Platform.isIOS) return 'iPhone';
    return Platform.operatingSystem;
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    final savedDevice = _prefs?.getString(_prefDeviceId);
    if (savedDevice != null && savedDevice.isNotEmpty) {
      _deviceId = savedDevice;
    } else {
      _deviceId = const Uuid().v4();
      await _prefs?.setString(_prefDeviceId, _deviceId);
    }

    final rawConfig = _prefs?.getString(_prefRemoteConfig);
    if (rawConfig != null && rawConfig.isNotEmpty) {
      try {
        final map = jsonDecode(rawConfig) as Map<String, dynamic>;
        _remoteConfig = RemoteConfig.fromJson(map);
      } catch (_) {}
    }

    final rawSession = _prefs?.getString(_prefSession);
    if (rawSession != null && rawSession.isNotEmpty) {
      try {
        final map = jsonDecode(rawSession) as Map<String, dynamic>;
        _session = LicenseSession.fromJson(map);
      } catch (_) {}
    }

    final rawCatalog = _prefs?.getString(_prefCatalog);
    if (rawCatalog != null && rawCatalog.isNotEmpty) {
      try {
        final list = jsonDecode(rawCatalog) as List<dynamic>;
        _catalog = list
            .whereType<Map<String, dynamic>>()
            .map(CatalogPreset.fromJson)
            .where((c) => c.url.isNotEmpty)
            .toList();
      } catch (_) {}
    }

    unawaited(fetchRemoteConfig());
    unawaited(fetchCatalog());
  }

  Future<String> getInstalledAppVersion() async {
    if (!Platform.isAndroid) return appVersion;
    try {
      final ver = await _alarmChannel.invokeMethod<String>('getAppVersion');
      if (ver != null && ver.trim().isNotEmpty) {
        return ver.trim();
      }
    } catch (_) {}
    return appVersion;
  }

  int _compareSemver(String a, String b) {
    final partsA = a
        .split(RegExp(r'[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final partsB = b
        .split(RegExp(r'[^0-9]+'))
        .where((s) => s.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final len = partsA.length > partsB.length ? partsA.length : partsB.length;
    for (int i = 0; i < len; i++) {
      final va = i < partsA.length ? partsA[i] : 0;
      final vb = i < partsB.length ? partsB[i] : 0;
      if (va != vb) return va > vb ? 1 : -1;
    }
    return 0;
  }

  bool isUpdateAvailable({String? installedVersion}) {
    final current = (installedVersion ?? appVersion).trim();
    final minVer = _remoteConfig.minVersion.trim();
    if (minVer.isNotEmpty && _compareSemver(minVer, current) > 0) {
      return true;
    }
    if (_latestGithubVersion.isNotEmpty &&
        _latestGithubApkUrl.startsWith('https://') &&
        _compareSemver(_latestGithubVersion, current) > 0) {
      return true;
    }
    return false;
  }

  bool _isAllowedGithubRawUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == 'raw.githubusercontent.com' ||
        host == 'gist.githubusercontent.com';
  }

  Future<void> checkGithubReleaseUpdate({bool force = false}) async {
    final repo = _remoteConfig.githubRepo.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$').hasMatch(repo)) {
      return;
    }
    if (!force &&
        _lastGithubReleaseCheck != null &&
        DateTime.now().difference(_lastGithubReleaseCheck!).inMinutes < 10) {
      return;
    }
    _lastGithubReleaseCheck = DateTime.now();
    try {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final rawTag = ((data['tag_name'] as String?) ?? '').trim();
      final cleanVer = rawTag.replaceFirst(RegExp(r'^[vV]+'), '');
      final assets = data['assets'];
      String apkUrl = '';
      if (assets is List) {
        for (final item in assets) {
          if (item is Map<String, dynamic>) {
            final dl = ((item['browser_download_url'] as String?) ?? '').trim();
            if (dl.toLowerCase().startsWith('https://') &&
                dl.toLowerCase().endsWith('.apk')) {
              apkUrl = dl;
              break;
            }
          }
        }
      }
      if (cleanVer.isNotEmpty && apkUrl.isNotEmpty) {
        _latestGithubVersion = cleanVer;
        _latestGithubApkUrl = apkUrl;
      }
    } catch (_) {}
  }

  Future<bool> syncAllFromServerAndGithub({bool forceReleaseCheck = false}) async {
    bool serverOk = false;
    try {
      final prevRev = _remoteConfig.otaRevision;
      final response = await http
          .get(Uri.parse('$baseUrl?action=config'))
          .timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['ok'] == true &&
            body['remote_config'] is Map<String, dynamic>) {
          _remoteConfig = RemoteConfig.fromJson(
            body['remote_config'] as Map<String, dynamic>,
          );
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
          _lastSyncedAt = DateTime.now();
          serverOk = true;
        }
      }
      if (!serverOk && _isAllowedGithubRawUrl(_remoteConfig.githubSyncUrl)) {
        final ghResp = await http
            .get(Uri.parse(_remoteConfig.githubSyncUrl.trim()))
            .timeout(const Duration(seconds: 6));
        if (ghResp.statusCode == 200) {
          final decoded = jsonDecode(ghResp.body) as Map<String, dynamic>;
          final cfgMap = decoded['remote_config'] is Map<String, dynamic>
              ? decoded['remote_config'] as Map<String, dynamic>
              : decoded;
          final merged = <String, dynamic>{
            ..._remoteConfig.toJson(),
            ...cfgMap,
          };
          _remoteConfig = RemoteConfig.fromJson(merged);
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
          _lastSyncedAt = DateTime.now();
        }
      }
      if (_remoteConfig.otaRevision != prevRev || serverOk) {
        unawaited(fetchCatalog());
      }
      unawaited(checkGithubReleaseUpdate(force: forceReleaseCheck));
    } catch (_) {}

    if (_session != null) {
      return await revalidateInBackground();
    }
    return true;
  }

  Future<ApkInstallResult> downloadAndInstallApkUpdate({
    required String url,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      return const ApkInstallResult(
        started: false,
        message: 'Installer APK hanya tersedia di Android.',
      );
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      return const ApkInstallResult(
        started: false,
        message: 'Link update APK wajib menggunakan HTTPS yang valid.',
      );
    }
    final client = http.Client();
    IOSink? sink;
    try {
      final dirPath =
          await _alarmChannel.invokeMethod<String>('getApkUpdateDir');
      if (dirPath == null || dirPath.trim().isEmpty) {
        return const ApkInstallResult(
          started: false,
          message: 'Direktori update tidak tersedia.',
        );
      }
      final filePath = '$dirPath/mendek_update.apk';
      final tempFile = File('$filePath.part');
      if (await tempFile.exists()) await tempFile.delete();

      final request = http.Request('GET', uri);
      final streamed =
          await client.send(request).timeout(const Duration(seconds: 25));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        return ApkInstallResult(
          started: false,
          message: 'Gagal mengunduh update (HTTP ${streamed.statusCode}).',
        );
      }
      final total = streamed.contentLength ?? 0;
      int received = 0;
      sink = tempFile.openWrite();
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress((received / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      final finalFile = File(filePath);
      if (await finalFile.exists()) await finalFile.delete();
      await tempFile.rename(filePath);
      onProgress?.call(1.0);

      final res = await _alarmChannel.invokeMapMethod<String, dynamic>(
        'installApkFile',
        {'path': filePath},
      );
      if (res?['needsPermission'] == true) {
        return const ApkInstallResult(
          started: false,
          needsPermission: true,
          message:
              'Aktifkan izin "Izinkan dari sumber ini" lalu ketuk Update 1-Klik lagi.',
        );
      }
      if (res?['started'] == true) {
        return const ApkInstallResult(started: true);
      }
      return ApkInstallResult(
        started: false,
        message: (res?['error'] as String?) ?? 'Gagal membuka installer APK.',
      );
    } catch (_) {
      return const ApkInstallResult(
        started: false,
        message: 'Koneksi terputus saat mengunduh paket update APK.',
      );
    } finally {
      await sink?.close();
      client.close();
    }
  }

  Future<BatterySnapshotData?> getBatterySnapshot() async {
    if (!Platform.isAndroid) return null;
    try {
      final snap = await _alarmChannel
          .invokeMapMethod<String, dynamic>('getBatterySnapshot');
      if (snap == null) return null;
      final pct = (snap['levelPct'] as num?)?.toInt() ?? 100;
      final isCharging = snap['isCharging'] == true;
      final temp = (snap['tempCelsius'] as num?)?.toDouble() ?? 30.0;
      return BatterySnapshotData(
        levelPct: pct,
        isCharging: isCharging,
        tempCelsius: temp,
      );
    } catch (_) {
      return null;
    }
  }

  Future<PickedLocalMedia?> pickLocalMedia() async {
    if (!Platform.isAndroid) return null;
    final res = await _alarmChannel
        .invokeMapMethod<String, dynamic>('pickLocalMedia');
    if (res == null) return null;
    final path = (res['path'] as String?) ?? '';
    final name = (res['name'] as String?) ?? 'masteran_lokal.mp3';
    final isAudioOnly = res['isAudioOnly'] == true;
    if (path.isEmpty) return null;
    return PickedLocalMedia(
      path: path,
      name: name,
      isAudioOnly: isAudioOnly,
    );
  }

  Future<void> startAmbientTherapy(String mode, int volumePct) async {
    if (!Platform.isAndroid) return;
    try {
      await _alarmChannel.invokeMethod('startAmbientTherapy', {
        'mode': mode,
        'volumePct': volumePct.clamp(0, 100),
      });
    } catch (_) {}
  }

  Future<void> setAmbientVolume(int volumePct) async {
    if (!Platform.isAndroid) return;
    try {
      await _alarmChannel.invokeMethod('setAmbientVolume', {
        'volumePct': volumePct.clamp(0, 100),
      });
    } catch (_) {}
  }

  Future<void> stopAmbientTherapy() async {
    if (!Platform.isAndroid) return;
    try {
      await _alarmChannel.invokeMethod('stopAmbientTherapy');
    } catch (_) {}
  }

  Future<void> setScreenDim(bool dimmed) async {
    if (!Platform.isAndroid) return;
    try {
      await _alarmChannel.invokeMethod('setScreenDim', {'dimmed': dimmed});
    } catch (_) {}
  }

  Future<bool> shareToSocial({
    required String text,
    String subject = 'Info Mendek Arena',
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _alarmChannel.invokeMethod<bool>('shareToSocial', {
        'text': text,
        'subject': subject,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> _readBatteryPingFields() async {
    if (!Platform.isAndroid) return const {};
    try {
      final snap = await _alarmChannel
          .invokeMapMethod<String, dynamic>('getBatterySnapshot');
      if (snap == null) return const {};
      final fields = <String, String>{};
      if (snap['levelPct'] != null) {
        fields['battery_pct'] = '${snap['levelPct']}';
      }
      if (snap['tempCelsius'] != null) {
        fields['battery_temp'] = '${snap['tempCelsius']}';
      }
      if (snap['isCharging'] != null) {
        fields['is_charging'] = snap['isCharging'] == true ? 'true' : 'false';
      }
      return fields;
    } catch (_) {
      return const {};
    }
  }

  Future<List<CatalogPreset>> fetchCatalog() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl?action=catalog'))
          .timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['ok'] == true && body['catalog'] is List<dynamic>) {
          final items = (body['catalog'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(CatalogPreset.fromJson)
              .where((c) => c.url.isNotEmpty)
              .toList();
          _catalog = items;
          await _prefs?.setString(
            _prefCatalog,
            jsonEncode(items.map((e) => e.toJson()).toList()),
          );
        }
      }
    } catch (_) {
      // Gunakan katalog cache lokal saat offline
    }
    return _catalog;
  }

  Future<RemoteConfig> fetchRemoteConfig() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl?action=config'))
          .timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['ok'] == true &&
            body['remote_config'] is Map<String, dynamic>) {
          _remoteConfig = RemoteConfig.fromJson(
            body['remote_config'] as Map<String, dynamic>,
          );
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
        }
      }
    } catch (_) {
      // Gunakan konfigurasi cache lokal saat offline
    }
    return _remoteConfig;
  }

  Future<VerifyResult> verifyKey(String rawKey) async {
    final trimmedKey = rawKey.trim();
    if (trimmedKey.isEmpty) {
      return const VerifyResult(
        ok: false,
        message: 'Masukkan Key akses terlebih dahulu.',
      );
    }

    try {
      final response = await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'verify',
              'key': trimmedKey,
              'device_id': _deviceId,
              'device_name': _deviceLabel,
              'app_version': appVersion,
            },
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && body['ok'] == true) {
        lastAuthError = null;
        final userMap = body['user'] as Map<String, dynamic>;
        _session = LicenseSession.fromJson(userMap);
        await _prefs?.setString(_prefSession, jsonEncode(_session!.toJson()));

        if (body['remote_config'] is Map<String, dynamic>) {
          _remoteConfig = RemoteConfig.fromJson(
            body['remote_config'] as Map<String, dynamic>,
          );
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
        }
        return VerifyResult(
          ok: true,
          message: (body['message'] as String?) ?? 'Aktivasi berhasil.',
        );
      }

      return VerifyResult(
        ok: false,
        message:
            (body['message'] as String?) ?? 'Key tidak valid atau ditolak server.',
      );
    } catch (_) {
      return const VerifyResult(
        ok: false,
        message:
            'Gagal terhubung ke server limopancer.com. Pastikan internet HP aktif.',
      );
    }
  }

  Future<bool> revalidateInBackground() async {
    if (_session == null) return false;
    if (isSessionExpired) {
      lastAuthError = 'License expired, silakan meminta yang baru.';
      await logout();
      return false;
    }
    try {
      final batteryFields = await _readBatteryPingFields();
      final response = await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'ping',
              'key': _session!.key,
              'device_id': _deviceId,
              'app_version': appVersion,
              ...batteryFields,
            },
          )
          .timeout(const Duration(seconds: 7));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['ok'] == true) {
        if (body['user'] is Map<String, dynamic>) {
          final u = body['user'] as Map<String, dynamic>;
          final newExp = u['expires_at'] as String?;
          final newLabel = (u['label_user'] as String?)?.trim();
          _session = _session!.copyWith(
            labelUser: (newLabel != null && newLabel.isNotEmpty) ? newLabel : null,
            expiresAt: newExp,
            clearExpiresAt: newExp == null || newExp.trim().isEmpty,
          );
          await _prefs?.setString(_prefSession, jsonEncode(_session!.toJson()));
        }
        if (body['remote_config'] is Map<String, dynamic>) {
          _remoteConfig = RemoteConfig.fromJson(
            body['remote_config'] as Map<String, dynamic>,
          );
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
          _lastSyncedAt = DateTime.now();
        }
        if (isSessionExpired) {
          lastAuthError = 'License expired, silakan meminta yang baru.';
          await logout();
          return false;
        }
        unawaited(fetchCatalog());
        return true;
      }

      if (response.statusCode == 403 || response.statusCode == 404) {
        final reason = (body['reason'] as String?) ?? '';
        final srvMsg = (body['message'] as String?) ?? '';
        final low = srvMsg.toLowerCase();
        if (reason == 'expired' ||
            low.contains('expired') ||
            low.contains('kadaluwarsa') ||
            low.contains('berakhir')) {
          lastAuthError = 'License expired, silakan meminta yang baru.';
        } else {
          lastAuthError =
              srvMsg.isNotEmpty ? srvMsg : 'Akses license berakhir.';
        }
        await logout();
        return false;
      }
    } catch (_) {
      // Tetap pertahankan sesi saat offline kecuali jika sudah lewat tanggal expired
      if (isSessionExpired) {
        lastAuthError = 'License expired, silakan meminta yang baru.';
        await logout();
        return false;
      }
    }
    return true;
  }

  Future<void> sendMonitoringPing({String? playingNow}) async {
    if (_session == null) return;
    try {
      final batteryFields = await _readBatteryPingFields();
      await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'ping',
              'key': _session!.key,
              'device_id': _deviceId,
              'app_version': appVersion,
              if (playingNow != null && playingNow.isNotEmpty)
                'playing_now': playingNow,
              ...batteryFields,
            },
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }


  Future<VerifyResult> issueMusicBoxKey() async {
    if (_session == null) {
      return const VerifyResult(ok: false, message: 'Login Key diperlukan.');
    }
    try {
      final response = await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'issue_music_box_key',
              'key': _session!.key,
              'device_id': _deviceId,
            },
          )
          .timeout(const Duration(seconds: 10));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && body['ok'] == true) {
        final box = (body['music_box'] as Map<String, dynamic>?) ?? {};
        _session = _session!.copyWith(
          musicBoxKey: (box['box_key'] as String?) ?? '',
          musicBoxDeviceId: (box['box_device_id'] as String?) ?? '',
          musicBoxName: (box['box_name'] as String?) ?? '',
          musicBoxSyncedAt: box['synced_at'] as String?,
        );
        await _prefs?.setString(_prefSession, jsonEncode(_session!.toJson()));
        return VerifyResult(
          ok: true,
          message: (body['message'] as String?) ?? 'Key Musik Box siap.',
        );
      }
      return VerifyResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal membuat Key Musik Box.',
      );
    } catch (_) {
      return const VerifyResult(
        ok: false,
        message: 'Gagal terhubung ke server untuk membuat Key Musik Box.',
      );
    }
  }

  Future<VerifyResult> bindMusicBox({
    required String boxKey,
    required String boxDeviceId,
    required String boxName,
  }) async {
    if (_session == null) {
      return const VerifyResult(ok: false, message: 'Login Key diperlukan.');
    }
    try {
      final response = await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'bind_music_box',
              'key': _session!.key,
              'device_id': _deviceId,
              'box_key': boxKey,
              'box_device_id': boxDeviceId,
              'box_name': boxName,
            },
          )
          .timeout(const Duration(seconds: 10));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && body['ok'] == true) {
        final box = (body['music_box'] as Map<String, dynamic>?) ?? {};
        _session = _session!.copyWith(
          musicBoxKey: (box['box_key'] as String?) ?? boxKey,
          musicBoxDeviceId: (box['box_device_id'] as String?) ?? boxDeviceId,
          musicBoxName: (box['box_name'] as String?) ?? boxName,
          musicBoxSyncedAt: box['synced_at'] as String?,
        );
        await _prefs?.setString(_prefSession, jsonEncode(_session!.toJson()));
        return VerifyResult(
          ok: true,
          message: (body['message'] as String?) ?? 'Musik Box terkunci & sinkron!',
        );
      }
      return VerifyResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal mengikat Musik Box.',
      );
    } catch (_) {
      return const VerifyResult(
        ok: false,
        message: 'Gagal menghubungi server untuk mengikat Musik Box.',
      );
    }
  }

  Future<void> logout() async {
    _session = null;
    await _prefs?.remove(_prefSession);
  }

  Uri buildWhatsAppUri() {
    final cleanedPhone = _remoteConfig.waNumber.replaceAll(RegExp(r'[^0-9]'), '');
    final encodedMsg = Uri.encodeComponent(_remoteConfig.waMessage);
    return Uri.parse('https://wa.me/$cleanedPhone?text=$encodedMsg');
  }

  Uri buildTikTokUri() {
    final raw = _remoteConfig.tiktokUrl.trim();
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Uri.parse(raw);
    }
    return Uri.parse('https://www.tiktok.com/@mendekarena');
  }
}
