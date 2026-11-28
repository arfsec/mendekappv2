import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/music_box_service.dart';

class MusicBoxSheet extends StatefulWidget {
  final Color accentColor;
  const MusicBoxSheet({super.key, required this.accentColor});

  static Future<void> show(
    BuildContext context, {
    required Color accentColor,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MusicBoxSheet(accentColor: accentColor),
    );
  }

  @override
  State<MusicBoxSheet> createState() => _MusicBoxSheetState();
}

class _MusicBoxSheetState extends State<MusicBoxSheet> {
  bool _issuing = false;
  bool _scanning = false;
  bool _syncing = false;
  bool _encrypting = false;
  String? _statusText;
  bool _statusOk = true;
  List<BleBoxDevice> _devices = const [];

  Future<void> _handleIssueKey() async {
    setState(() {
      _issuing = true;
      _statusText = null;
    });
    final res = await ApiService.instance.issueMusicBoxKey();
    if (!mounted) return;
    setState(() {
      _issuing = false;
      _statusOk = res.ok;
      _statusText = res.message;
    });
  }

  Future<void> _handleScanBle() async {
    setState(() {
      _scanning = true;
      _statusText = null;
      _devices = const [];
    });
    try {
      final list = await MusicBoxService.instance.scanNearbyBoxes();
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _devices = list;
        if (list.isEmpty) {
          _statusOk = false;
          _statusText =
              'Smart Musik Box (MendekBox) tidak ditemukan. Pastikan Musik Box menyala & Bluetooth HP aktif.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _statusOk = false;
        _statusText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleSyncDevice(BleBoxDevice device) async {
    setState(() {
      _syncing = true;
      _statusText = null;
    });
    final res = await MusicBoxService.instance.pairAndSyncToBox(device);
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _statusOk = res.ok;
      _statusText = res.message;
    });
  }

  Future<void> _handleEncryptAudio() async {
    setState(() {
      _encrypting = true;
      _statusText = null;
    });
    final res = await MusicBoxService.instance.encryptPickedAudioToMbx();
    if (!mounted) return;
    setState(() {
      _encrypting = false;
      _statusOk = res.ok;
      _statusText = res.outputPath.isNotEmpty
          ? '${res.message}\nLokasi file: ${res.outputPath}'
          : res.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ApiService.instance.session;
    final boxKey = session?.musicBoxKey ?? '';
    final boxId = session?.musicBoxDeviceId ?? '';
    final boxName = session?.musicBoxName ?? '';
    final accent = widget.accentColor;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF2F2F7),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC7C7CC),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.speaker_rounded, color: accent),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smart Musik Box (1 Key)',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                        Text(
                          '1 Aplikasi Sewa = Maksimal 1 Musik Box Offline Anti-Copy',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6E6E73),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_statusText != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: _statusOk
                        ? const Color(0xFFECFDF5)
                        : const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _statusOk
                          ? const Color(0xFFA7F3D0)
                          : const Color(0xFFFECACA),
                    ),
                  ),
                  child: Text(
                    _statusText!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _statusOk
                          ? const Color(0xFF065F46)
                          : const Color(0xFF991B1B),
                    ),
                  ),
                ),

              // LANGKAH 1: TERBITKAN 1 KEY MUSIK BOX
              _StepCard(
                step: '1',
                title: 'Buat 1 Key Musik Box',
                subtitle: boxKey.isEmpty
                    ? 'Kuota: 0 / 1 terpakai. Setiap penyewa berhak membuat tepat 1 Key untuk mengunci 1 unit Musik Box.'
                    : 'Key permanen milik akun Anda (Kuota: 1 / 1 Terpakai).',
                accent: accent,
                child: boxKey.isEmpty
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          minimumSize: const Size(double.infinity, 46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _issuing ? null : _handleIssueKey,
                        icon: _issuing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.vpn_key_rounded, size: 18),
                        label: Text(
                          _issuing
                              ? 'Menerbitkan Key...'
                              : 'Buat 1 Key Musik Box',
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'MUSIK BOX KEY',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                  Text(
                                    boxKey,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w800,
                                      fontFamily: 'monospace',
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: boxKey));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Key Musik Box disalin.'),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.copy_rounded, size: 20),
                            ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 12),

              // LANGKAH 2: PAIRING BLUETOOTH BLE & KIRIM JADWAL KE MEMORI BOX
              _StepCard(
                step: '2',
                title: 'Kirim Jadwal via Bluetooth (Tahan BLE OFF)',
                subtitle: boxId.isNotEmpty
                    ? 'Terkunci ke $boxName ($boxId). Setelah sinkron, Bluetooth HP boleh dimatikan dan jadwal tetap tersimpan di Musik Box!'
                    : 'Scan perangkat MendekBox via Bluetooth BLE untuk mengunci Key & menyalin seluruh jadwal aktif ke memori Musik Box.',
                accent: accent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent.withOpacity(0.12),
                        foregroundColor: accent,
                        minimumSize: const Size(double.infinity, 46),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed:
                          boxKey.isEmpty || _scanning || _syncing
                              ? null
                              : _handleScanBle,
                      icon: _scanning
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: accent,
                              ),
                            )
                          : const Icon(
                              Icons.bluetooth_searching_rounded,
                              size: 18,
                            ),
                      label: Text(
                        _scanning
                            ? 'Mencari Musik Box (3.5d)...'
                            : 'Scan & Kirim Jadwal ke Musik Box',
                      ),
                    ),
                    if (_devices.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final d in _devices)
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: d.isMendekBox
                                  ? accent.withOpacity(0.5)
                                  : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.speaker_rounded,
                              color: d.isMendekBox
                                  ? accent
                                  : const Color(0xFF64748B),
                            ),
                            title: Text(
                              d.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            subtitle: Text(
                              '${d.address} • Sinyal ${d.rssi} dBm',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                              ),
                              onPressed:
                                  _syncing ? null : () => _handleSyncDevice(d),
                              child: Text(_syncing ? 'Sync...' : 'Kunci & Sync'),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // LANGKAH 3: ENKRIPSI FILE AUDIO MP3 -> .MBX ANTI-COPY
              _StepCard(
                step: '3',
                title: 'Kunci File Audio ke .MBX Anti-Copy',
                subtitle:
                    'Mengubah MP3/WAV menjadi format .mbx terenkripsi khusus untuk ID Musik Box Anda agar tidak bisa dicopy/diputar di perangkat lain.',
                accent: accent,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: (boxKey.isEmpty || boxId.isEmpty || _encrypting)
                      ? null
                      : _handleEncryptAudio,
                  icon: _encrypting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.lock_rounded, size: 18),
                  label: Text(
                    _encrypting
                        ? 'Mengunci File Audio...'
                        : 'Pilih Audio & Kunci Jadi .MBX',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StepCard extends StatelessWidget {
  final String step;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget child;

  const _StepCard({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
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
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  step,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1C1C1E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF6E6E73),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}
