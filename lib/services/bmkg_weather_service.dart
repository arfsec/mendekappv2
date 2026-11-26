import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notif_service.dart';

class RegionOption {
  final String code;
  final String name;

  const RegionOption({required this.code, required this.name});

  factory RegionOption.fromJson(Map<String, dynamic> json) {
    return RegionOption(
      code: (json['code'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
    );
  }
}

class BmkgForecastSlot {
  final DateTime localTime;
  final int tempC;
  final int humidityPct;
  final double rainMm;
  final String weatherDesc;
  final int weatherCode;
  final double windKmh;

  const BmkgForecastSlot({
    required this.localTime,
    required this.tempC,
    required this.humidityPct,
    required this.rainMm,
    required this.weatherDesc,
    required this.weatherCode,
    required this.windKmh,
  });

  bool get isRain {
    final lower = weatherDesc.toLowerCase();
    return lower.contains('hujan') ||
        lower.contains('petir') ||
        lower.contains('badai') ||
        rainMm >= 0.5 ||
        weatherCode >= 60;
  }

  bool get isDaytime => localTime.hour >= 6 && localTime.hour <= 17;

  bool get isHotOrSunny {
    if (isRain || !isDaytime) return false;
    final lower = weatherDesc.toLowerCase();
    return lower.contains('cerah') || tempC >= 29;
  }

  String get hourLabel =>
      '${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
        'local_datetime': _formatIsoLocal(localTime),
        't': tempC,
        'hu': humidityPct,
        'tp': rainMm,
        'weather_desc': weatherDesc,
        'weather': weatherCode,
        'ws': windKmh,
      };

  static String _formatIsoLocal(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  static BmkgForecastSlot? fromJson(Map<String, dynamic> json) {
    final rawDt = (json['local_datetime'] as String? ?? '').trim();
    if (rawDt.isEmpty) return null;
    final parsedDt = DateTime.tryParse(rawDt.replaceFirst(' ', 'T'));
    if (parsedDt == null) return null;
    return BmkgForecastSlot(
      localTime: parsedDt,
      tempC: (num.tryParse('${json['t'] ?? 28}') ?? 28).round(),
      humidityPct: (num.tryParse('${json['hu'] ?? 75}') ?? 75).round(),
      rainMm: (num.tryParse('${json['tp'] ?? 0}') ?? 0).toDouble(),
      weatherDesc: (json['weather_desc'] as String? ?? 'Berawan').trim(),
      weatherCode: (num.tryParse('${json['weather'] ?? 3}') ?? 3).round(),
      windKmh: (num.tryParse('${json['ws'] ?? 5}') ?? 5).toDouble(),
    );
  }
}

class BmkgTomorrowSummary {
  final String adm4;
  final String regionLabel;
  final DateTime todayDate;
  final DateTime tomorrowDate;
  final List<BmkgForecastSlot> tomorrowSlots;
  final List<BmkgForecastSlot> rainSlots;
  final List<BmkgForecastSlot> hotSlots;
  final int minTempC;
  final int maxTempC;

  const BmkgTomorrowSummary({
    required this.adm4,
    required this.regionLabel,
    required this.todayDate,
    required this.tomorrowDate,
    required this.tomorrowSlots,
    required this.rainSlots,
    required this.hotSlots,
    required this.minTempC,
    required this.maxTempC,
  });

  String get shortRegion {
    final parts = regionLabel.split(',');
    return parts.first.trim().isNotEmpty ? parts.first.trim() : regionLabel;
  }

  String get tomorrowDateLabel {
    const days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'Mei',
      'Jun',
      'Jul',
      'Agu',
      'Sep',
      'Okt',
      'Nov',
      'Des',
    ];
    final dayName = days[(tomorrowDate.weekday - 1).clamp(0, 6)];
    final monthName = months[(tomorrowDate.month - 1).clamp(0, 11)];
    return '$dayName, ${tomorrowDate.day} $monthName';
  }

  String get rainHoursText {
    if (rainSlots.isEmpty) return 'Tidak ada hujan diprakirakan';
    return rainSlots.map((s) => s.hourLabel).join(', ');
  }

  String get hotHoursText {
    if (hotSlots.isEmpty) {
      return 'Cenderung berawan/teduh (maks $maxTempC°C)';
    }
    return '${hotSlots.map((s) => s.hourLabel).join(', ')} (maks $maxTempC°C)';
  }

  String get birdCareTip {
    if (rainSlots.isNotEmpty && hotSlots.isNotEmpty) {
      return 'Jemur gacoan aman sekitar ${hotSlots.first.hourLabel}, lalu siapkan kerodong sebelum hujan jam ${rainSlots.first.hourLabel}.';
    }
    if (rainSlots.isNotEmpty) {
      return 'Besok dominan hujan mulai jam ${rainSlots.first.hourLabel}. Sebaiknya gacoan cukup diangin-anginkan di teras + kerodong.';
    }
    return 'Besok cuaca relatif cerah/kering ($minTempC–$maxTempC°C). Sangat bagus untuk jadwal jemur & masteran rutin.';
  }

  String get notificationTitle =>
      'BMKG Besok ($tomorrowDateLabel) • $shortRegion';

  String get notificationShortBody {
    final hotShort = hotSlots.isNotEmpty
        ? hotSlots.map((s) => s.hourLabel).take(3).join(', ')
        : 'Teduh $maxTempC°C';
    final rainShort = rainSlots.isNotEmpty
        ? rainSlots.map((s) => s.hourLabel).take(3).join(', ')
        : 'Nihil';
    return 'Panas: $hotShort • Hujan: $rainShort';
  }

  String get notificationBigBody {
    return 'Wilayah: $regionLabel\n'
        'Suhu Besok: $minTempC°C – $maxTempC°C\n'
        'Panas / Cerah (Jemur): $hotHoursText\n'
        'Prakiraan Hujan: $rainHoursText\n'
        'Saran: $birdCareTip';
  }
}

class BmkgDetectResult {
  final bool ok;
  final String message;
  final String? adm4;
  final String? regionLabel;

  const BmkgDetectResult({
    required this.ok,
    required this.message,
    this.adm4,
    this.regionLabel,
  });
}

class BmkgWeatherService {
  BmkgWeatherService._();
  static final BmkgWeatherService instance = BmkgWeatherService._();

  static const MethodChannel _channel =
      MethodChannel('com.mendekarena.mendek_arena_masteran/alarm');
  static const String _wilayahBase = 'https://wilayah.id/api';
  static const String _bmkgBase =
      'https://api.bmkg.go.id/publik/prakiraan-cuaca';

  static const String _prefAdm4 = 'mendek_bmkg_adm4_v1';
  static const String _prefRegionLabel = 'mendek_bmkg_region_label_v1';
  static const String _prefAutoNotif = 'mendek_bmkg_auto_notif_v1';
  static const String _prefNotifHour = 'mendek_bmkg_notif_hour_v1';
  static const String _prefNotifMinute = 'mendek_bmkg_notif_minute_v1';
  static const String _prefCachedSlots = 'mendek_bmkg_cached_slots_v1';
  static const String _prefLastFetchMs = 'mendek_bmkg_last_fetch_ms_v1';
  static const String _prefLastNotifDate = 'mendek_bmkg_last_notif_date_v1';

  SharedPreferences? _prefs;
  String _adm4 = '';
  String _regionLabel = '';
  bool _autoNotifEnabled = true;
  int _notifHour = 19;
  int _notifMinute = 0;
  List<BmkgForecastSlot> _cachedSlots = const [];
  int _lastFetchMs = 0;

  String get adm4 => _adm4;
  String get regionLabel => _regionLabel;
  bool get hasRegion => _adm4.isNotEmpty;
  bool get autoNotifEnabled => _autoNotifEnabled;
  int get notifHour => _notifHour;
  int get notifMinute => _notifMinute;
  String get formattedNotifTime =>
      '${_notifHour.toString().padLeft(2, '0')}:${_notifMinute.toString().padLeft(2, '0')}';

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _adm4 = _prefs?.getString(_prefAdm4) ?? '';
    _regionLabel = _prefs?.getString(_prefRegionLabel) ?? '';
    _autoNotifEnabled = _prefs?.getBool(_prefAutoNotif) ?? true;
    _notifHour = _prefs?.getInt(_prefNotifHour) ?? 19;
    _notifMinute = _prefs?.getInt(_prefNotifMinute) ?? 0;
    _lastFetchMs = _prefs?.getInt(_prefLastFetchMs) ?? 0;

    final rawSlots = _prefs?.getString(_prefCachedSlots);
    if (rawSlots != null && rawSlots.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSlots) as List<dynamic>;
        _cachedSlots = decoded
            .whereType<Map<String, dynamic>>()
            .map(BmkgForecastSlot.fromJson)
            .whereType<BmkgForecastSlot>()
            .toList();
      } catch (_) {}
    }
  }

  Future<void> setAutoNotifEnabled(bool enabled) async {
    await init();
    _autoNotifEnabled = enabled;
    await _prefs?.setBool(_prefAutoNotif, enabled);
    if (!enabled) {
      await NotifService.instance.cancelBmkgReminder();
    } else {
      await ensureReminderScheduled();
    }
  }

  Future<void> setNotifTime(int hour, int minute) async {
    await init();
    _notifHour = hour.clamp(0, 23);
    _notifMinute = minute.clamp(0, 59);
    await _prefs?.setInt(_prefNotifHour, _notifHour);
    await _prefs?.setInt(_prefNotifMinute, _notifMinute);
    await ensureReminderScheduled();
  }

  Future<void> setManualRegion({
    required String adm4,
    required String regionLabel,
  }) async {
    await init();
    _adm4 = adm4.trim();
    _regionLabel = regionLabel.trim();
    await _prefs?.setString(_prefAdm4, _adm4);
    await _prefs?.setString(_prefRegionLabel, _regionLabel);
    await _prefs?.remove(_prefLastNotifDate);
    _lastFetchMs = 0;
  }

  BmkgTomorrowSummary? getTomorrowSummary({DateTime? referenceNow}) {
    if (_adm4.isEmpty || _cachedSlots.isEmpty) return null;
    final now = referenceNow ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final tomorrowSlots = _cachedSlots.where((s) {
      return s.localTime.year == tomorrow.year &&
          s.localTime.month == tomorrow.month &&
          s.localTime.day == tomorrow.day;
    }).toList()
      ..sort((a, b) => a.localTime.compareTo(b.localTime));

    if (tomorrowSlots.isEmpty) return null;

    final rainSlots = tomorrowSlots.where((s) => s.isRain).toList();
    var hotSlots = tomorrowSlots.where((s) => s.isHotOrSunny).toList();
    if (hotSlots.isEmpty) {
      final daytimeClear =
          tomorrowSlots.where((s) => !s.isRain && s.isDaytime).toList();
      if (daytimeClear.isNotEmpty) {
        daytimeClear.sort((a, b) => b.tempC.compareTo(a.tempC));
        final topTemp = daytimeClear.first.tempC;
        hotSlots = daytimeClear
            .where((s) => s.tempC >= topTemp - 1)
            .toList()
          ..sort((a, b) => a.localTime.compareTo(b.localTime));
      }
    }

    int minT = tomorrowSlots.first.tempC;
    int maxT = tomorrowSlots.first.tempC;
    for (final s in tomorrowSlots) {
      if (s.tempC < minT) minT = s.tempC;
      if (s.tempC > maxT) maxT = s.tempC;
    }

    return BmkgTomorrowSummary(
      adm4: _adm4,
      regionLabel: _regionLabel.isNotEmpty ? _regionLabel : _adm4,
      todayDate: today,
      tomorrowDate: tomorrow,
      tomorrowSlots: tomorrowSlots,
      rainSlots: rainSlots,
      hotSlots: hotSlots,
      minTempC: minT,
      maxTempC: maxT,
    );
  }

  Future<List<RegionOption>> fetchProvinces() =>
      _fetchRegionList('$_wilayahBase/provinces.json');

  Future<List<RegionOption>> fetchRegencies(String provinceCode) =>
      _fetchRegionList('$_wilayahBase/regencies/$provinceCode.json');

  Future<List<RegionOption>> fetchDistricts(String regencyCode) =>
      _fetchRegionList('$_wilayahBase/districts/$regencyCode.json');

  Future<List<RegionOption>> fetchVillages(String districtCode) =>
      _fetchRegionList('$_wilayahBase/villages/$districtCode.json');

  Future<List<RegionOption>> _fetchRegionList(String url) async {
    final resp = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw Exception('Gagal mengambil daftar wilayah (${resp.statusCode})');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawList = decoded['data'] as List<dynamic>? ?? const [];
    return rawList
        .whereType<Map<String, dynamic>>()
        .map(RegionOption.fromJson)
        .where((r) => r.code.isNotEmpty && r.name.isNotEmpty)
        .toList();
  }

  String _normalizeName(String raw) {
    var s = raw.toLowerCase().trim();
    const replacements = <String, String>{
      'daerah khusus ibukota jakarta': 'dki jakarta',
      'jakarta': 'dki jakarta',
      'daerah istimewa yogyakarta': 'di yogyakarta',
      'yogyakarta': 'di yogyakarta',
      'nanggroe aceh darussalam': 'aceh',
      'special region of yogyakarta': 'di yogyakarta',
      'east java': 'jawa timur',
      'west java': 'jawa barat',
      'central java': 'jawa tengah',
      'north sumatra': 'sumatera utara',
      'west sumatra': 'sumatera barat',
      'south sumatra': 'sumatera selatan',
    };
    if (replacements.containsKey(s)) {
      s = replacements[s]!;
    }
    s = s
        .replaceAll(RegExp(r'\b(provinsi|prov\.?|kota administrasi|kabupaten administrasi|kabupaten|kab\.?|kota|kecamatan|kec\.?|kelurahan|kel\.?|desa)\b'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s;
  }

  RegionOption? _bestMatch(List<RegionOption> options, String query, {bool preferKota = false}) {
    if (options.isEmpty) return null;
    final cleanQ = _normalizeName(query);
    if (cleanQ.isEmpty) return null;

    RegionOption? best;
    int bestScore = -1;
    for (final opt in options) {
      final optNorm = _normalizeName(opt.name);
      int score = 0;
      if (optNorm == cleanQ) {
        score = 100;
      } else if (optNorm.contains(cleanQ) || cleanQ.contains(optNorm)) {
        score = 70;
      } else {
        final qTokens = cleanQ.split(' ').where((w) => w.length >= 3).toSet();
        final oTokens = optNorm.split(' ').where((w) => w.length >= 3).toSet();
        final overlap = qTokens.intersection(oTokens).length;
        if (overlap > 0) {
          score = overlap * 25;
        }
      }
      if (score > 0 && preferKota && opt.name.toLowerCase().contains('kota')) {
        score += 5;
      }
      if (score > bestScore) {
        bestScore = score;
        best = opt;
      }
    }
    return bestScore > 0 ? best : null;
  }

  Future<BmkgDetectResult> detectRegionFromGps({
    bool requestPermission = true,
  }) async {
    await init();
    if (!Platform.isAndroid) {
      return const BmkgDetectResult(
        ok: false,
        message: 'Deteksi GPS otomatis hanya tersedia di Android.',
      );
    }

    var permStatus = await Permission.locationWhenInUse.status;
    if (!permStatus.isGranted) {
      if (!requestPermission) {
        return const BmkgDetectResult(
          ok: false,
          message: 'Izin lokasi belum diaktifkan.',
        );
      }
      permStatus = await Permission.locationWhenInUse.request();
      if (!permStatus.isGranted) {
        return const BmkgDetectResult(
          ok: false,
          message: 'Izin lokasi ditolak. Pilih wilayah manual jika perlu.',
        );
      }
    }

    try {
      final geo = await _channel
          .invokeMapMethod<String, dynamic>('getDeviceRegionInfo');
      if (geo == null ||
          geo['permissionDenied'] == true ||
          geo['locationUnavailable'] == true) {
        return const BmkgDetectResult(
          ok: false,
          message:
              'Lokasi GPS HP belum aktif/terkunci. Aktifkan GPS atau pilih wilayah manual.',
        );
      }

      final adminArea = (geo['adminArea'] as String? ?? '').trim();
      final subAdminArea = (geo['subAdminArea'] as String? ?? '').trim();
      final locality = (geo['locality'] as String? ?? '').trim();
      final subLocality = (geo['subLocality'] as String? ?? '').trim();

      if (adminArea.isEmpty && subAdminArea.isEmpty) {
        return const BmkgDetectResult(
          ok: false,
          message: 'Nama wilayah dari GPS belum terbaca. Gunakan Pilih Wilayah.',
        );
      }

      final provinces = await fetchProvinces();
      final prov = _bestMatch(provinces, adminArea);
      if (prov == null) {
        return BmkgDetectResult(
          ok: false,
          message: 'Provinsi "$adminArea" belum cocok otomatis. Pilih manual.',
        );
      }

      final regencies = await fetchRegencies(prov.code);
      final isKota = subAdminArea.toLowerCase().contains('kota');
      final reg = _bestMatch(regencies, subAdminArea, preferKota: isKota) ??
          _bestMatch(regencies, locality, preferKota: isKota) ??
          regencies.first;

      final districts = await fetchDistricts(reg.code);
      final dist = _bestMatch(districts, locality) ??
          _bestMatch(districts, subLocality) ??
          districts.first;

      final villages = await fetchVillages(dist.code);
      final vil = _bestMatch(villages, subLocality) ??
          _bestMatch(villages, locality) ??
          villages.first;

      final label = '${vil.name}, ${dist.name}, ${reg.name}';
      await setManualRegion(adm4: vil.code, regionLabel: label);
      return BmkgDetectResult(
        ok: true,
        message: 'Wilayah BMKG terdeteksi: $label',
        adm4: vil.code,
        regionLabel: label,
      );
    } catch (e) {
      return BmkgDetectResult(
        ok: false,
        message: 'Gagal mendeteksi wilayah otomatis: $e',
      );
    }
  }

  Future<void> ensureReminderScheduled() async {
    await init();
    if (!_autoNotifEnabled) return;
    final summary = getTomorrowSummary();
    if (summary == null) return;
    await NotifService.instance.scheduleDailyBmkgReminder(
      hour: _notifHour,
      minute: _notifMinute,
      title: summary.notificationTitle,
      body: summary.notificationBigBody,
    );
  }

  Future<BmkgTomorrowSummary?> refreshForecastAndAutoNotify({
    bool forceFetch = false,
    bool forceSendNotification = false,
  }) async {
    await init();

    if (_adm4.isEmpty) {
      final detected = await detectRegionFromGps(requestPermission: false);
      if (!detected.ok) return null;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cacheFresh =
        !forceFetch && _cachedSlots.isNotEmpty && (nowMs - _lastFetchMs) < 3 * 3600 * 1000;

    if (!cacheFresh) {
      try {
        final uri = Uri.parse('$_bmkgBase?adm4=${Uri.encodeComponent(_adm4)}');
        final resp = await http.get(uri).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final dataList = body['data'] as List<dynamic>? ?? const [];
          if (dataList.isNotEmpty && dataList.first is Map<String, dynamic>) {
            final firstBlock = dataList.first as Map<String, dynamic>;
            final lokasi = firstBlock['lokasi'];
            if (lokasi is Map<String, dynamic>) {
              final desa = (lokasi['desa'] as String? ?? '').trim();
              final kec = (lokasi['kecamatan'] as String? ?? '').trim();
              final kotkab = (lokasi['kotkab'] as String? ?? '').trim();
              final composed = [desa, kec, kotkab]
                  .where((s) => s.isNotEmpty)
                  .join(', ');
              if (composed.isNotEmpty) {
                _regionLabel = composed;
                await _prefs?.setString(_prefRegionLabel, _regionLabel);
              }
            }

            final cuacaDays = firstBlock['cuaca'] as List<dynamic>? ?? const [];
            final parsedSlots = <BmkgForecastSlot>[];
            for (final dayGroup in cuacaDays) {
              if (dayGroup is List) {
                for (final item in dayGroup) {
                  if (item is Map<String, dynamic>) {
                    final slot = BmkgForecastSlot.fromJson(item);
                    if (slot != null) parsedSlots.add(slot);
                  }
                }
              }
            }

            if (parsedSlots.isNotEmpty) {
              _cachedSlots = parsedSlots;
              _lastFetchMs = nowMs;
              await _prefs?.setString(
                _prefCachedSlots,
                jsonEncode(parsedSlots.map((s) => s.toJson()).toList()),
              );
              await _prefs?.setInt(_prefLastFetchMs, _lastFetchMs);
            }
          }
        }
      } catch (_) {
        // Gunakan cache offline jika koneksi BMKG sedang lambat
      }
    }

    final summary = getTomorrowSummary();
    if (summary == null) return null;

    if (_autoNotifEnabled) {
      await ensureReminderScheduled();
      final todayKey =
          '${summary.todayDate.year}-${summary.todayDate.month.toString().padLeft(2, '0')}-${summary.todayDate.day.toString().padLeft(2, '0')}';
      final lastSent = _prefs?.getString(_prefLastNotifDate) ?? '';
      if (forceSendNotification || lastSent != todayKey) {
        await NotifService.instance.showBmkgTomorrowNotification(
          title: summary.notificationTitle,
          summaryBody: summary.notificationShortBody,
          bigBody: summary.notificationBigBody,
        );
        await _prefs?.setString(_prefLastNotifDate, todayKey);
      }
    }

    return summary;
  }
}
