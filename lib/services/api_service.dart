import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

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
  final String minVersion;

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
    this.minVersion = '1.0.0',
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
      appName: ((json['app_name'] as String?) ?? '').trim().isNotEmpty ? (json['app_name'] as String).trim() : 'Mendek Arena',
      logoUrl: ((json['logo_url'] as String?) ?? '').trim(),
      fadeInDefaultSec: int.tryParse('${json['fade_in_default_sec'] ?? 25}') ?? 25,
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
      minVersion: (json['min_version'] as String?) ?? '1.0.0',
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
        'min_version': minVersion,
      };
}

class LicenseSession {
  final String key;
  final String labelUser;
  final String? expiresAt;
  final String boundDeviceId;

  const LicenseSession({
    required this.key,
    required this.labelUser,
    this.expiresAt,
    required this.boundDeviceId,
  });

  factory LicenseSession.fromJson(Map<String, dynamic> json) {
    return LicenseSession(
      key: (json['key'] as String?) ?? '',
      labelUser: (json['label_user'] as String?) ?? 'Kicau Mania',
      expiresAt: json['expires_at'] as String?,
      boundDeviceId: (json['bound_device_id'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label_user': labelUser,
        'expires_at': expiresAt,
        'bound_device_id': boundDeviceId,
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

  static const String baseUrl = 'http://limopancer.com/mendek/api.php';
  static const String appVersion = '1.1.0';

  static const String _prefDeviceId = 'mendek_device_id_v1';
  static const String _prefSession = 'mendek_license_session_v1';
  static const String _prefRemoteConfig = 'mendek_remote_config_v1';

  SharedPreferences? _prefs;
  String _deviceId = '';
  LicenseSession? _session;
  RemoteConfig _remoteConfig = const RemoteConfig();

  String get deviceId => _deviceId;
  LicenseSession? get session => _session;
  RemoteConfig get remoteConfig => _remoteConfig;
  bool get hasValidSession => _session != null && _session!.key.isNotEmpty;

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

    unawaited(fetchRemoteConfig());
  }

  Future<RemoteConfig> fetchRemoteConfig() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl?action=config'))
          .timeout(const Duration(seconds: 7));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['ok'] == true && body['remote_config'] is Map<String, dynamic>) {
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
      return const VerifyResult(ok: false, message: 'Masukkan Key akses terlebih dahulu.');
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
        message: (body['message'] as String?) ?? 'Key tidak valid atau ditolak server.',
      );
    } catch (_) {
      return const VerifyResult(
        ok: false,
        message:
            'Gagal terhubung ke server limopancer.com. Pastikan internet HP aktif.',
      );
    }
  }

  /// Mengembalikan false hanya jika server secara eksplisit menolak/mencabut key.
  /// Jika HP sedang offline / timeout, sesi lokal tetap diizinkan agar mode offline tetap berjalan.
  Future<bool> revalidateInBackground() async {
    if (_session == null) return false;
    try {
      final response = await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'ping',
              'key': _session!.key,
              'device_id': _deviceId,
            },
          )
          .timeout(const Duration(seconds: 7));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['ok'] == true) {
        if (body['remote_config'] is Map<String, dynamic>) {
          _remoteConfig = RemoteConfig.fromJson(
            body['remote_config'] as Map<String, dynamic>,
          );
          await _prefs?.setString(
            _prefRemoteConfig,
            jsonEncode(_remoteConfig.toJson()),
          );
        }
        return true;
      }

      if (response.statusCode == 403 || response.statusCode == 404) {
        await logout();
        return false;
      }
    } catch (_) {
      // Tetap pertahankan sesi saat offline
    }
    return true;
  }

  Future<void> sendMonitoringPing({String? playingNow}) async {
    if (_session == null) return;
    try {
      await http
          .post(
            Uri.parse(baseUrl),
            body: {
              'action': 'ping',
              'key': _session!.key,
              'device_id': _deviceId,
              if (playingNow != null && playingNow.isNotEmpty)
                'playing_now': playingNow,
            },
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
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
