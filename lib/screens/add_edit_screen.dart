import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../models/schedule.dart';
import '../services/api_service.dart';
import '../services/db_service.dart';
import '../services/notif_service.dart';
import '../services/url_helper.dart';

class AddEditResult {
  final Schedule schedule;
  final bool autoDownloadOffline;

  const AddEditResult({
    required this.schedule,
    this.autoDownloadOffline = false,
  });
}

class AddEditScreen extends StatefulWidget {
  final Schedule? existingSchedule;

  const AddEditScreen({super.key, this.existingSchedule});

  @override
  State<AddEditScreen> createState() => _AddEditScreenState();
}

class _AddEditScreenState extends State<AddEditScreen> {
  Color get _appleBlue => ApiService.instance.remoteConfig.accentColor;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();

  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late Set<int> _selectedDays;
  late bool _isActive;
  late bool _useInterval;
  late int _playMinutes;
  late int _pauseMinutes;

  ParsedVideoUrl? _detectedUrl;
  bool _isSaving = false;
  bool _isResolvingLink = false;
  bool _autoDownloadOffline = true;

  static const List<MapEntry<int, String>> _dayItems = [
    MapEntry(1, 'Sen'),
    MapEntry(2, 'Sel'),
    MapEntry(3, 'Rab'),
    MapEntry(4, 'Kam'),
    MapEntry(5, 'Jum'),
    MapEntry(6, 'Sab'),
    MapEntry(7, 'Min'),
  ];

  bool get _isEditing => widget.existingSchedule != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingSchedule;
    if (existing != null) {
      _nameController.text = existing.name;
      _urlController.text = existing.url;
      _startTime = TimeOfDay(
        hour: existing.startHour,
        minute: existing.startMinute,
      );
      _endTime = TimeOfDay(
        hour: existing.endHour,
        minute: existing.endMinute,
      );
      _selectedDays = existing.days.toSet();
      _isActive = existing.isActive;
      _useInterval = existing.hasInterval;
      _playMinutes = existing.playMinutes > 0 ? existing.playMinutes : 15;
      _pauseMinutes = existing.pauseMinutes > 0 ? existing.pauseMinutes : 5;
      _detectedUrl = UrlHelper.parseUrl(existing.url);
      _autoDownloadOffline = existing.platform == 'youtube' && !existing.isOfflineReady;
    } else {
      _autoDownloadOffline = true;
      _startTime = const TimeOfDay(hour: 3, minute: 0);
      _endTime = const TimeOfDay(hour: 7, minute: 0);
      _selectedDays = {1, 2, 3, 4, 5, 6, 7};
      _isActive = true;
      _useInterval = true;
      _playMinutes = 15;
      _pauseMinutes = 5;
    }

    _urlController.addListener(_onUrlChanged);
  }

  void _onUrlChanged() {
    final parsed = UrlHelper.parseUrl(_urlController.text);
    if (parsed?.videoId != _detectedUrl?.videoId ||
        parsed?.platform != _detectedUrl?.platform ||
        parsed?.isShortLink != _detectedUrl?.isShortLink) {
      setState(() {
        _detectedUrl = parsed;
      });
    }
  }

  Future<void> _pasteUrlFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) {
      _urlController.text = text;
      _onUrlChanged();
      final parsed = UrlHelper.parseUrl(text);
      if (parsed != null && parsed.isShortLink) {
        await _resolveShortlinkInBackground(text);
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clipboard kosong. Salin link terlebih dahulu.'),
        ),
      );
    }
  }

  Future<void> _resolveShortlinkInBackground(String raw) async {
    setState(() => _isResolvingLink = true);
    final resolved = await UrlHelper.resolveUrl(raw);
    if (!mounted) return;
    setState(() {
      _isResolvingLink = false;
      if (resolved != null && !resolved.isShortLink) {
        _detectedUrl = resolved;
        _urlController.text = resolved.originalUrl;
      }
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final initial = isStart ? _startTime : _endTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? 'PILIH JAM MULAI' : 'PILIH JAM SELESAI',
      cancelText: 'BATAL',
      confirmText: 'PILIH',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  String _formatTime(TimeOfDay t) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  void _adjustPlayMinutes(int delta) {
    setState(() {
      _playMinutes = (_playMinutes + delta).clamp(1, 180);
    });
  }

  void _adjustPauseMinutes(int delta) {
    setState(() {
      _pauseMinutes = (_pauseMinutes + delta).clamp(1, 60);
    });
  }

  Future<void> _saveSchedule() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih minimal 1 hari aktif.')),
      );
      return;
    }

    if (_startTime.hour == _endTime.hour &&
        _startTime.minute == _endTime.minute) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Jam mulai dan jam selesai tidak boleh sama persis.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final resolved = await UrlHelper.resolveUrl(_urlController.text);
      if (resolved == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Link video tidak valid.')),
          );
          setState(() => _isSaving = false);
        }
        return;
      }

      final existing = widget.existingSchedule;
      final bool keepLocalFile = existing != null &&
          existing.platform == resolved.platform &&
          existing.videoId == resolved.videoId;

      final schedule = Schedule(
        id: existing?.id ?? const Uuid().v4(),
        name: _nameController.text.trim(),
        url: resolved.originalUrl,
        platform: resolved.platform,
        videoId: resolved.videoId,
        startHour: _startTime.hour,
        startMinute: _startTime.minute,
        endHour: _endTime.hour,
        endMinute: _endTime.minute,
        days: _selectedDays.toList()..sort(),
        isActive: _isActive,
        createdAt: existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        playMinutes: _useInterval ? _playMinutes : 0,
        pauseMinutes: _useInterval ? _pauseMinutes : 0,
        localFilePath: keepLocalFile ? existing.localFilePath : null,
      );

      if (_isEditing) {
        await DbService.instance.updateSchedule(schedule);
      } else {
        await DbService.instance.insertSchedule(schedule);
      }

      await NotifService.instance.scheduleNotificationsFor(schedule);

      final bool shouldAutoDownload = _autoDownloadOffline &&
          resolved.platform == 'youtube' &&
          !schedule.isOfflineReady &&
          ApiService.instance.remoteConfig.enableOfflineDownload;

      if (mounted) {
        Navigator.of(context).pop(
          AddEditResult(
            schedule: schedule,
            autoDownloadOffline: shouldAutoDownload,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal menyimpan jadwal: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditing ? 'Ubah Jadwal' : 'Jadwal Baru',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF1C1C1E),
          ),
        ),
        iconTheme: IconThemeData(color: _appleBlue),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Color(0xFFE5E5EA)),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE5E5EA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nama Masteran',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _nameController,
                      style: const TextStyle(fontSize: 17),
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        hintText: 'Contoh: Cililin Tembakan Pagi',
                        fillColor: const Color(0xFFF2F2F7),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Nama masteran wajib diisi.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Link Video (YouTube / TikTok)',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                        TextButton.icon(
                          onPressed:
                              _isResolvingLink ? null : _pasteUrlFromClipboard,
                          icon: Icon(
                            Icons.paste_rounded,
                            size: 18,
                            color: _appleBlue,
                          ),
                          label: Text(
                            _isResolvingLink ? 'Memeriksa...' : 'Tempel Link',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _appleBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _urlController,
                      style: const TextStyle(fontSize: 15),
                      keyboardType: TextInputType.url,
                      maxLines: 2,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText:
                            'https://youtu.be/... atau https://vt.tiktok.com/...',
                        fillColor: const Color(0xFFF2F2F7),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: UrlHelper.validateUrl,
                    ),
                    if (_detectedUrl != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF93C5FD)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _detectedUrl!.platform == 'youtube'
                                  ? Icons.play_circle_fill_rounded
                                  : Icons.music_note_rounded,
                              color: _appleBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _detectedUrl!.isShortLink
                                    ? 'Terdeteksi: TikTok Shortlink (${_detectedUrl!.videoId}) • Siap diputar & diselesaikan otomatis'
                                    : 'Terdeteksi: ${_detectedUrl!.platformLabel} (ID: ${_detectedUrl!.videoId})',
                                style: const TextStyle(
                                  color: Color(0xFF1E3A8A),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_detectedUrl!.platform == 'youtube' &&
                          ApiService.instance.remoteConfig.enableOfflineDownload) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _autoDownloadOffline
                                  ? const Color(0xFF93C5FD)
                                  : const Color(0xFFE5E5EA),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.offline_pin_rounded,
                                color: _autoDownloadOffline
                                    ? _appleBlue
                                    : const Color(0xFF8E8E93),
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Otomatis Unduh Offline ke HP',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF1C1C1E),
                                      ),
                                    ),
                                    Text(
                                      '100% berbunyi saat layar terkunci tanpa kuota internet',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF6E6E73),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              CupertinoSwitch(
                                value: _autoDownloadOffline,
                                activeColor: _appleBlue,
                                onChanged: (val) =>
                                    setState(() => _autoDownloadOffline = val),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE5E5EA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Jam Putar Otomatis (24 Jam)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _TimePickerBox(
                            label: 'Jam Mulai',
                            timeText: _formatTime(_startTime),
                            accentColor: _appleBlue,
                            onTap: () => _pickTime(isStart: true),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _TimePickerBox(
                            label: 'Jam Selesai',
                            timeText: _formatTime(_endTime),
                            accentColor: _appleBlue,
                            onTap: () => _pickTime(isStart: false),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _useInterval
                        ? const Color(0xFF93C5FD)
                        : const Color(0xFFE5E5EA),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Jeda Otomatis (Istirahat Burung)',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _useInterval
                                    ? 'Setiap putar $_playMinutes menit, jeda $_pauseMinutes menit'
                                    : 'Video diputar terus tanpa jeda hingga jam selesai',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        CupertinoSwitch(
                          value: _useInterval,
                          activeColor: _appleBlue,
                          onChanged: (val) =>
                              setState(() => _useInterval = val),
                        ),
                      ],
                    ),
                    if (_useInterval) ...[
                      const Divider(height: 24, color: Color(0xFFE5E5EA)),
                      const Text(
                        'Pilihan Cepat:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF3A3A3C),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _PresetChip(
                            label: '15 mnt / Jeda 5 mnt',
                            selected:
                                _playMinutes == 15 && _pauseMinutes == 5,
                            accentColor: _appleBlue,
                            onTap: () => setState(() {
                              _playMinutes = 15;
                              _pauseMinutes = 5;
                            }),
                          ),
                          _PresetChip(
                            label: '20 mnt / Jeda 5 mnt',
                            selected:
                                _playMinutes == 20 && _pauseMinutes == 5,
                            accentColor: _appleBlue,
                            onTap: () => setState(() {
                              _playMinutes = 20;
                              _pauseMinutes = 5;
                            }),
                          ),
                          _PresetChip(
                            label: '30 mnt / Jeda 10 mnt',
                            selected:
                                _playMinutes == 30 && _pauseMinutes == 10,
                            accentColor: _appleBlue,
                            onTap: () => setState(() {
                              _playMinutes = 30;
                              _pauseMinutes = 10;
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _MinuteStepperRow(
                        label: 'Lama Memutar',
                        valueMinutes: _playMinutes,
                        accentColor: _appleBlue,
                        onMinusFive: () => _adjustPlayMinutes(-5),
                        onMinusOne: () => _adjustPlayMinutes(-1),
                        onPlusOne: () => _adjustPlayMinutes(1),
                        onPlusFive: () => _adjustPlayMinutes(5),
                      ),
                      const SizedBox(height: 12),
                      _MinuteStepperRow(
                        label: 'Lama Jeda (Diam)',
                        valueMinutes: _pauseMinutes,
                        accentColor: _appleBlue,
                        onMinusFive: () => _adjustPauseMinutes(-5),
                        onMinusOne: () => _adjustPauseMinutes(-1),
                        onPlusOne: () => _adjustPauseMinutes(1),
                        onPlusFive: () => _adjustPauseMinutes(5),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE5E5EA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Hari Aktif',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1C1C1E),
                          ),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _selectedDays = {1, 2, 3, 4, 5, 6, 7};
                                });
                              },
                              child: Text('Semua',
                                  style: TextStyle(color: _appleBlue)),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _selectedDays = {1, 2, 3, 4, 5};
                                });
                              },
                              child: Text('Sen-Jum',
                                  style: TextStyle(color: _appleBlue)),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _dayItems.map((entry) {
                        final selected = _selectedDays.contains(entry.key);
                        return FilterChip(
                          label: Text(
                            entry.value,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF1C1C1E),
                            ),
                          ),
                          selected: selected,
                          selectedColor: _appleBlue,
                          backgroundColor: const Color(0xFFF2F2F7),
                          checkmarkColor: Colors.white,
                          side: BorderSide.none,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          onSelected: (value) {
                            setState(() {
                              if (value) {
                                _selectedDays.add(entry.key);
                              } else {
                                _selectedDays.remove(entry.key);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const Divider(height: 24, color: Color(0xFFE5E5EA)),
                    Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Aktifkan Jadwal Ini',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Video akan otomatis diputar pada jam yang ditentukan.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        CupertinoSwitch(
                          value: _isActive,
                          activeColor: _appleBlue,
                          onChanged: (val) => setState(() => _isActive = val),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _appleBlue),
                  onPressed: _isSaving ? null : _saveSchedule,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 24),
                  label: Text(
                    _isSaving ? 'MENYIMPAN...' : 'SIMPAN JADWAL',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : const Color(0xFF1D4ED8),
        ),
      ),
      selected: selected,
      selectedColor: accentColor,
      backgroundColor: const Color(0xFFEFF6FF),
      side: BorderSide.none,
      onSelected: (_) => onTap(),
    );
  }
}

class _MinuteStepperRow extends StatelessWidget {
  final String label;
  final int valueMinutes;
  final Color accentColor;
  final VoidCallback onMinusFive;
  final VoidCallback onMinusOne;
  final VoidCallback onPlusOne;
  final VoidCallback onPlusFive;

  const _MinuteStepperRow({
    required this.label,
    required this.valueMinutes,
    required this.accentColor,
    required this.onMinusFive,
    required this.onMinusOne,
    required this.onPlusOne,
    required this.onPlusFive,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1C1C1E),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _StepButton(
                text: '-5', accentColor: accentColor, onTap: onMinusFive),
            const SizedBox(width: 6),
            _StepButton(
                text: '-1', accentColor: accentColor, onTap: onMinusOne),
            Expanded(
              child: Center(
                child: Text(
                  '$valueMinutes menit',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    color: accentColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            _StepButton(
                text: '+1', accentColor: accentColor, onTap: onPlusOne),
            const SizedBox(width: 6),
            _StepButton(
                text: '+5', accentColor: accentColor, onTap: onPlusFive),
          ],
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final String text;
  final Color accentColor;
  final VoidCallback onTap;

  const _StepButton({
    required this.text,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 44,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: const Color(0xFFF2F2F7),
          side: const BorderSide(color: Color(0xFFD1D1D6)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onTap,
        child: Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: accentColor,
          ),
        ),
      ),
    );
  }
}

class _TimePickerBox extends StatelessWidget {
  final String label;
  final String timeText;
  final Color accentColor;
  final VoidCallback onTap;

  const _TimePickerBox({
    required this.label,
    required this.timeText,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF93C5FD), width: 1.5),
          color: const Color(0xFFEFF6FF),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1E3A8A),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  timeText,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: accentColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Icon(Icons.access_time_filled, color: accentColor),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
