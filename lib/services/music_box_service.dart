import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'api_service.dart';
import 'db_service.dart';

class BleBoxDevice {
  final String address;
  final String name;
  final int rssi;
  final bool isMendekBox;

  const BleBoxDevice({
    required this.address,
    required this.name,
    required this.rssi,
    required this.isMendekBox,
  });

  factory BleBoxDevice.fromMap(Map<dynamic, dynamic> map) {
    return BleBoxDevice(
      address: (map['address'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Perangkat BLE',
      rssi: (map['rssi'] as num?)?.toInt() ?? -80,
      isMendekBox: map['isMendekBox'] == true,
    );
  }
}

class MusicBoxSyncResult {
  final bool ok;
  final String message;
  final String boxDeviceId;
  final String boxName;

  const MusicBoxSyncResult({
    required this.ok,
    required this.message,
    this.boxDeviceId = '',
    this.boxName = '',
  });
}

class MbxEncryptResult {
  final bool ok;
  final String message;
  final String outputPath;
  final String fileName;

  const MbxEncryptResult({
    required this.ok,
    required this.message,
    this.outputPath = '',
    this.fileName = '',
  });
}

class MusicBoxService {
  MusicBoxService._();
  static final MusicBoxService instance = MusicBoxService._();

  static const MethodChannel _channel =
      MethodChannel('com.mendekarena.mendek_arena_masteran/alarm');

  Future<bool> ensureBluetoothPermissions() async {
    final scanStatus = await Permission.bluetoothScan.request();
    final connectStatus = await Permission.bluetoothConnect.request();
    if (scanStatus.isGranted && connectStatus.isGranted) {
      return true;
    }
    // Android 11 ke bawah memakai izin lokasi untuk scan BLE
    final locStatus = await Permission.locationWhenInUse.request();
    return locStatus.isGranted ||
        (scanStatus.isGranted && connectStatus.isGranted);
  }

  Future<List<BleBoxDevice>> scanNearbyBoxes() async {
    final granted = await ensureBluetoothPermissions();
    if (!granted) {
      throw Exception(
        'Izin Bluetooth / Lokasi terdekat ditolak. Aktifkan di Pengaturan HP.',
      );
    }
    final rawList =
        await _channel.invokeMethod<List<dynamic>>('scanMusicBoxes');
    if (rawList == null) return const [];
    return rawList
        .whereType<Map<dynamic, dynamic>>()
        .map(BleBoxDevice.fromMap)
        .where((d) => d.address.isNotEmpty)
        .toList();
  }

  Future<MusicBoxSyncResult> pairAndSyncToBox(BleBoxDevice device) async {
    final session = ApiService.instance.session;
    if (session == null || session.musicBoxKey.trim().isEmpty) {
      return const MusicBoxSyncResult(
        ok: false,
        message: 'Buat 1 Key Musik Box terlebih dahulu sebelum pairing.',
      );
    }

    final schedules = await DbService.instance.getAllSchedules();
    final activeSchedules = schedules.where((s) => s.isActive).toList();
    final payload = {
      'cmd': 'SYNC_ALL',
      'box_key': session.musicBoxKey.trim().toUpperCase(),
      'expires_at': session.expiresAt ?? '',
      'epoch_sec': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'schedules': activeSchedules
          .map(
            (s) => {
              'id': s.id,
              'name': s.name,
              'is_active': s.isActive,
              'start_h': s.startHour,
              'start_m': s.startMinute,
              'end_h': s.endHour,
              'end_m': s.endMinute,
              'play_min': s.playMinutes,
              'pause_min': s.pauseMinutes,
              'start_vol': s.startVolume,
              'target_vol': s.targetVolume,
              'fade_sec': s.fadeInSeconds,
              'days': s.days,
              'tracks': s.tracks.isNotEmpty
                  ? s.tracks
                      .map((t) => '/masteran/${_safeMbxFileName(t.title)}')
                      .toList()
                  : ['/masteran/${_safeMbxFileName(s.name)}'],
            },
          )
          .toList(),
    };

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'syncMusicBoxBle',
        {
          'address': device.address,
          'payloadJson': jsonEncode(payload),
        },
      );
      if (res == null || res['ok'] != true) {
        return MusicBoxSyncResult(
          ok: false,
          message:
              (res?['error'] as String?) ?? 'Gagal mengirim data ke Musik Box.',
        );
      }

      final boxDeviceId = ((res['boxDeviceId'] as String?) ?? '').trim();
      final boxName = ((res['boxName'] as String?) ?? device.name).trim();
      if (boxDeviceId.isEmpty) {
        return const MusicBoxSyncResult(
          ok: false,
          message: 'Musik Box tidak mengirimkan ID Chip unik.',
        );
      }

      final bindResp = await ApiService.instance.bindMusicBox(
        boxKey: session.musicBoxKey,
        boxDeviceId: boxDeviceId,
        boxName: boxName,
      );
      if (!bindResp.ok) {
        return MusicBoxSyncResult(
          ok: false,
          message: bindResp.message,
          boxDeviceId: boxDeviceId,
          boxName: boxName,
        );
      }

      return MusicBoxSyncResult(
        ok: true,
        message:
            'Berhasil dikunci & disinkron ke $boxName ($boxDeviceId). Bluetooth sekarang boleh dimatikan, data tetap tersimpan permanen di Musik Box!',
        boxDeviceId: boxDeviceId,
        boxName: boxName,
      );
    } on PlatformException catch (e) {
      return MusicBoxSyncResult(
        ok: false,
        message: e.message ?? 'Koneksi Bluetooth BLE gagal.',
      );
    } catch (e) {
      return MusicBoxSyncResult(
        ok: false,
        message: 'Terjadi kesalahan saat sync Musik Box: $e',
      );
    }
  }

  Future<MbxEncryptResult> encryptPickedAudioToMbx() async {
    final session = ApiService.instance.session;
    if (session == null ||
        session.musicBoxKey.trim().isEmpty ||
        session.musicBoxDeviceId.trim().isEmpty) {
      return const MbxEncryptResult(
        ok: false,
        message:
            'Pastikan Key Musik Box sudah dibuat dan sudah dipairing ke unit ESP32 Musik Box terlebih dahulu.',
      );
    }

    try {
      final picked =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('pickLocalMedia');
      if (picked == null) {
        return const MbxEncryptResult(
          ok: false,
          message: 'Pemilihan file audio dibatalkan.',
        );
      }
      final srcPath = (picked['path'] as String?) ?? '';
      final name = (picked['name'] as String?) ?? 'masteran.mp3';
      if (srcPath.isEmpty) {
        return const MbxEncryptResult(
          ok: false,
          message: 'Path file audio tidak ditemukan.',
        );
      }

      final outRes = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'encryptFileToMbx',
        {
          'srcPath': srcPath,
          'fileName': _safeMbxFileName(name),
          'boxKey': session.musicBoxKey.trim().toUpperCase(),
          'boxDeviceId': session.musicBoxDeviceId.trim().toUpperCase(),
        },
      );
      if (outRes == null || outRes['ok'] != true) {
        return MbxEncryptResult(
          ok: false,
          message: (outRes?['error'] as String?) ?? 'Gagal mengunci file audio.',
        );
      }

      return MbxEncryptResult(
        ok: true,
        message:
            'File berhasil dikunci ke format .mbx anti-copy! Salin ke folder /masteran/ di MicroSD Musik Box.',
        outputPath: (outRes['outputPath'] as String?) ?? '',
        fileName: (outRes['fileName'] as String?) ?? _safeMbxFileName(name),
      );
    } on PlatformException catch (e) {
      return MbxEncryptResult(
        ok: false,
        message: e.message ?? 'Gagal mengenkripsi audio ke .mbx.',
      );
    } catch (e) {
      return MbxEncryptResult(
        ok: false,
        message: 'Gagal memproses file audio: $e',
      );
    }
  }

  String _safeMbxFileName(String rawName) {
    final cleaned = rawName
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final base = cleaned.isEmpty ? 'masteran' : cleaned;
    return '$base.mbx';
  }
}
