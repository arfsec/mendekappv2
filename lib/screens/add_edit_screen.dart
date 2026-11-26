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
  final String initialBirdId;
  final List<BirdProfile> birdProfiles;

  const AddEditScreen({
    super.key,
    this.existingSchedule,
    this.initialBirdId = 'bird_default',
    this.birdProfiles = const [],
  });

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

  late String _selectedBirdId;
  late List<PlaylistTrack> _playlistTracks;
  late int _startVolume;
  late int _targetVolume;
  late int _fadeInSeconds;
  late String _ambientTherapy;
  late int _ambientVolume;
  late bool _batteryGuardEnabled;

  ParsedVideoUrl? _detectedUrl;
  bool _isSaving = false;
  bool _isResolvingLink = false;
  bool _isPickingLocal = false;
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

  static const List<Map<String, String>> _therapyOptions = [
    {'id': 'none', 'label': 'Tanpa Terapi'},
    {'id': 'water', 'label': 'Air Mengalir'},
    {'id': 'rain', 'label': 'Hujan Ringan'},
    {'id': 'forest', 'label': 'Hutan Pagi'},
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
      _autoDownloadOffline =
          existing.platform == 'youtube' && !existing.isOfflineReady;
      _selectedBirdId = existing.birdId;
      _playlistTracks = [...existing.tracks];
      _startVolume = existing.startVolume.clamp(0, 100);
      _targetVolume = existing.targetVolume.clamp(10, 100);
      _fadeInSeconds = existing.fadeInSeconds.clamp(0, 90);
      _ambientTherapy = existing.ambientTherapy;
      _ambientVolume = existing.ambientVolume.clamp(5, 80);
      _batteryGuardEnabled = existing.batteryGuardEnabled;
    } else {
      _autoDownloadOffline = true;
      _startTime = const TimeOfDay(hour: 3, minute: 0);
      _endTime = const TimeOfDay(hour: 7, minute: 0);
      _selectedDays = {1, 2, 3, 4, 5, 6, 7};
      _isActive = true;
      _useInterval = true;
      _playMinutes = 15;
      _pauseMinutes = 5;
      _selectedBirdId = widget.initialBirdId;
      _playlistTracks = [];
      _startVolume = 10;
      _targetVolume = 85;
      _fadeInSeconds =
          ApiService.instance.remoteConfig.fadeInDefaultSec.clamp(0, 90);
      _ambientTherapy = 'none';
      _ambientVolume = 20;
      _batteryGuardEnabled = true;
    }

    if (_startVolume > _targetVolume) {
      _startVolume = _targetVolume;
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

  Future<void> _pickLocalFile({bool addToPlaylist = false}) async {
    if (_isPickingLocal) return;
    setState(() => _isPickingLocal = true);
    try {
      final picked = await ApiService.instance.pickLocalMedia();
      if (!mounted) return;
      if (picked == null) {
        setState(() => _isPickingLocal = false);
        return;
      }
      final localUri = 'local://${picked.path}';
      final cleanTitle = picked.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      if (addToPlaylist) {
        setState(() {
          _playlistTracks.add(
            PlaylistTrack(
              id: const Uuid().v4(),
              title: cleanTitle.isNotEmpty ? cleanTitle : 'Masteran Lokal',
              url: localUri,
              platform: 'local',
              videoId: picked.name,
              localFilePath: picked.path,
            ),
          );
          if (_nameController.text.trim().isEmpty) {
            _nameController.text = cleanTitle;
          }
          if (_urlController.text.trim().isEmpty) {
            _urlController.text = localUri;
          }
        });
      } else {
        setState(() {
          _urlController.text = localUri;
          _autoDownloadOffline = false;
          if (_nameController.text.trim().isEmpty) {
            _nameController.text = cleanTitle;
          }
        });
        _onUrlChanged();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'File lokal "${picked.name}" siap diputar 100% offline!',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memilih file lokal: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingLocal = false);
      }
    }
  }

  Future<void> _addCurrentUrlToPlaylist() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tempel link atau pilih file lokal dulu sebelum masuk playlist.'),
        ),
      );
      return;
    }
    setState(() => _isResolvingLink = true);
    final resolved = await UrlHelper.resolveUrl(raw);
    if (!mounted) return;
    setState(() => _isResolvingLink = false);
    if (resolved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link video tidak valid.')),
      );
      return;
    }

    final trackTitle = resolved.platform == 'local'
        ? resolved.videoId.replaceAll(RegExp(r'\.[^.]+$'), '')
        : '${resolved.platformLabel} • ${resolved.videoId}';
    final alreadyExists = _playlistTracks.any(
      (t) =>
          t.originalUrlMatch(resolved.originalUrl) ||
          (resolved.platform != 'local' &&
              t.platform == resolved.platform &&
              t.videoId == resolved.videoId),
    );
    if (alreadyExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Isian tersebut sudah ada di playlist.')),
      );
      return;
    }

    setState(() {
      _playlistTracks.add(
        PlaylistTrack(
          id: const Uuid().v4(),
          title: trackTitle,
          url: resolved.originalUrl,
          platform: resolved.platform,
          videoId: resolved.videoId,
          localFilePath: resolved.platform == 'local' ? resolved.embedUrl : null,
        ),
      );
      _urlController.clear();
      _detectedUrl = null;
    });
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

    final rawInputUrl = _urlController.text.trim();
    if (_playlistTracks.isEmpty && rawInputUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Masukkan link YouTube/TikTok atau pilih file lokal HP.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final List<PlaylistTrack> finalTracks = [..._playlistTracks];
      ParsedVideoUrl? primaryResolved;

      if (rawInputUrl.isNotEmpty) {
        primaryResolved = await UrlHelper.resolveUrl(rawInputUrl);
        if (primaryResolved == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Link atau file media tidak valid.')),
            );
            setState(() => _isSaving = false);
          }
          return;
        }

        final hasInList = finalTracks.any(
          (t) =>
              t.url == primaryResolved!.originalUrl ||
              (primaryResolved.platform != 'local' &&
                  t.platform == primaryResolved.platform &&
                  t.videoId == primaryResolved.videoId),
        );
        if (!hasInList) {
          final existing = widget.existingSchedule;
          final String? preservedOffline = (existing != null &&
                  existing.platform == primaryResolved.platform &&
                  existing.videoId == primaryResolved.videoId)
              ? existing.localFilePath
              : null;
          finalTracks.insert(
            0,
            PlaylistTrack(
              id: const Uuid().v4(),
              title: primaryResolved.platform == 'local'
                  ? primaryResolved.videoId.replaceAll(RegExp(r'\.[^.]+$'), '')
                  : _nameController.text.trim(),
              url: primaryResolved.originalUrl,
              platform: primaryResolved.platform,
              videoId: primaryResolved.videoId,
              localFilePath: primaryResolved.platform == 'local'
                  ? primaryResolved.embedUrl
                  : preservedOffline,
            ),
          );
        }
      }

      if (finalTracks.isEmpty) {
        if (mounted) {
          setState(() => _isSaving = false);
        }
        return;
      }

      final primaryTrack = finalTracks.first;
      final existing = widget.existingSchedule;
      final bool keepExistingLocalFile = existing != null &&
          existing.platform == primaryTrack.platform &&
          existing.videoId == primaryTrack.videoId &&
          (existing.localFilePath ?? '').isNotEmpty;

      final String? resolvedLocalPath = primaryTrack.platform == 'local'
          ? (primaryTrack.localFilePath ??
              (primaryTrack.url.startsWith('local://')
                  ? primaryTrack.url.substring('local://'.length)
                  : primaryTrack.url))
          : (primaryTrack.localFilePath ??
              (keepExistingLocalFile ? existing.localFilePath : null));

      final schedule = Schedule(
        id: existing?.id ?? const Uuid().v4(),
        name: _nameController.text.trim(),
        url: primaryTrack.url,
        platform: primaryTrack.platform,
        videoId: primaryTrack.videoId,
        startHour: _startTime.hour,
        startMinute: _startTime.minute,
        endHour: _endTime.hour,
        endMinute: _endTime.minute,
        days: _selectedDays.toList()..sort(),
        isActive: _isActive,
        createdAt: existing?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        playMinutes: _useInterval ? _playMinutes : 0,
        pauseMinutes: _useInterval ? _pauseMinutes : 0,
        localFilePath: resolvedLocalPath,
        birdId: _selectedBirdId,
        tracks: finalTracks,
        startVolume: _startVolume.clamp(0, _targetVolume),
        targetVolume: _targetVolume.clamp(5, 100),
        fadeInSeconds: _fadeInSeconds,
        ambientTherapy: _ambientTherapy,
        ambientVolume: _ambientVolume,
        batteryGuardEnabled: _batteryGuardEnabled,
      );

      if (_isEditing) {
        await DbService.instance.updateSchedule(schedule);
      } else {
        await DbService.instance.insertSchedule(schedule);
      }

      await NotifService.instance.scheduleNotificationsFor(schedule);

      final bool shouldAutoDownload = _autoDownloadOffline &&
          primaryTrack.platform == 'youtube' &&
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
    final profiles = widget.birdProfiles;

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
              if (profiles.length > 1) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 18),
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
                        'Untuk Burung / Gacoan',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1C1C1E),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: profiles.map((b) {
                          final selected = _selectedBirdId == b.id;
                          return ChoiceChip(
                            label: Text(b.name),
                            selected: selected,
                            selectedColor: _appleBlue,
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF1C1C1E),
                            ),
                            onSelected: (_) =>
                                setState(() => _selectedBirdId = b.id),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ],
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
                        hintText: 'Contoh: Cililin + Kenari Pagi',
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
                        const Expanded(
                          child: Text(
                            'Sumber Audio / Video Masteran',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1C1C1E),
                            ),
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
                            _isResolvingLink ? 'Memeriksa...' : 'Tempel',
                            style: TextStyle(
                              fontSize: 13,
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
                      style: const TextStyle(fontSize: 14),
                      keyboardType: TextInputType.url,
                      maxLines: 2,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText:
                            'Link YouTube / TikTok atau tekan tombol Pilih File HP',
                        fillColor: const Color(0xFFF2F2F7),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (value) {
                        if (_playlistTracks.isNotEmpty &&
                            (value == null || value.trim().isEmpty)) {
                          return null;
                        }
                        return UrlHelper.validateUrl(value);
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _appleBlue,
                              side: const BorderSide(color: Color(0xFF93C5FD)),
                              minimumSize: const Size(0, 44),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _isPickingLocal
                                ? null
                                : () => _pickLocalFile(
                                      addToPlaylist: _playlistTracks.isNotEmpty,
                                    ),
                            icon: const Icon(Icons.folder_open_rounded, size: 18),
                            label: Text(
                              _isPickingLocal
                                  ? 'Menyalin...'
                                  : 'Pilih MP3 / MP4 HP',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
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
                            onPressed: _isResolvingLink
                                ? null
                                : _addCurrentUrlToPlaylist,
                            icon: const Icon(Icons.playlist_add_rounded, size: 20),
                            label: const Text(
                              '+ ke Playlist',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_playlistTracks.isNotEmpty) ...[
                      const SizedBox(height: 14),
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
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Playlist Multi-Isian (${_playlistTracks.length} track)',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const Text(
                                  'Rotasi otomatis',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...List.generate(_playlistTracks.length, (idx) {
                              final item = _playlistTracks[idx];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFFE5E7EB),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEFF6FF),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${idx + 1}. ${item.platformLabel}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: _appleBlue,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF1E293B),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                        color: Color(0xFFEF4444),
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _playlistTracks.removeAt(idx);
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                    ],
                    if (_detectedUrl != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
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
                                  : (_detectedUrl!.platform == 'local'
                                      ? Icons.audio_file_rounded
                                      : Icons.music_note_rounded),
                              color: _appleBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _detectedUrl!.platform == 'local'
                                    ? 'Terdeteksi: File Lokal HP (${_detectedUrl!.videoId}) • 100% Offline'
                                    : (_detectedUrl!.isShortLink
                                        ? 'Terdeteksi: TikTok Shortlink (${_detectedUrl!.videoId})'
                                        : 'Terdeteksi: ${_detectedUrl!.platformLabel} (ID: ${_detectedUrl!.videoId})'),
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
                  border: Border.all(color: const Color(0xFFE5E5EA)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Volume & Fade-In Halus (Anti Kaget)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Volume naik bertahap agar burung tidak stres saat masteran subuh menyala.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Volume Awal',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$_startVolume%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _appleBlue,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _startVolume.toDouble(),
                      min: 0,
                      max: _targetVolume.toDouble(),
                      divisions: _targetVolume > 5 ? _targetVolume ~/ 5 : 1,
                      activeColor: _appleBlue,
                      onChanged: (v) {
                        setState(() {
                          _startVolume = v.round();
                        });
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Volume Target',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$_targetVolume%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _appleBlue,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _targetVolume.toDouble(),
                      min: 10,
                      max: 100,
                      divisions: 18,
                      activeColor: _appleBlue,
                      onChanged: (v) {
                        setState(() {
                          _targetVolume = v.round();
                          if (_startVolume > _targetVolume) {
                            _startVolume = _targetVolume;
                          }
                        });
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Durasi Fade-In',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _fadeInSeconds == 0 ? 'Instan' : '$_fadeInSeconds detik',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _appleBlue,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _fadeInSeconds.toDouble(),
                      min: 0,
                      max: 90,
                      divisions: 18,
                      activeColor: _appleBlue,
                      onChanged: (v) => setState(() => _fadeInSeconds = v.round()),
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
                    color: _ambientTherapy != 'none'
                        ? const Color(0xFF93C5FD)
                        : const Color(0xFFE5E5EA),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Suara Terapi Alam Latar (Relaksasi)',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1C1C1E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Putar suara alam lembut di belakang audio masteran tanpa kuota.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF6E6E73)),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _therapyOptions.map((opt) {
                        final id = opt['id']!;
                        final label = opt['label']!;
                        final selected = _ambientTherapy == id;
                        return ChoiceChip(
                          label: Text(label),
                          selected: selected,
                          selectedColor: _appleBlue,
                          labelStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? Colors.white
                                : const Color(0xFF1C1C1E),
                          ),
                          onSelected: (_) =>
                              setState(() => _ambientTherapy = id),
                        );
                      }).toList(),
                    ),
                    if (_ambientTherapy != 'none') ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Volume Terapi Alam',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '$_ambientVolume%',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: _appleBlue,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: _ambientVolume.toDouble(),
                        min: 5,
                        max: 80,
                        divisions: 15,
                        activeColor: _appleBlue,
                        onChanged: (v) =>
                            setState(() => _ambientVolume = v.round()),
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
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Jeda Putar Otomatis (Interval)',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Putar masteran lalu diam agar burung tidak stres.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        CupertinoSwitch(
                          value: _useInterval,
                          activeColor: _appleBlue,
                          onChanged: (val) => setState(() => _useInterval = val),
                        ),
                      ],
                    ),
                    if (_useInterval) ...[
                      const Divider(height: 24, color: Color(0xFFE5E5EA)),
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
                                'Proteksi Panas & Layar OLED',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1C1C1E),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Redupkan layar otomatis saat HP panas atau baterai penuh di cas.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF6E6E73),
                                ),
                              ),
                            ],
                          ),
                        ),
                        CupertinoSwitch(
                          value: _batteryGuardEnabled,
                          activeColor: _appleBlue,
                          onChanged: (val) =>
                              setState(() => _batteryGuardEnabled = val),
                        ),
                      ],
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
                                'Masteran akan otomatis diputar pada jam yang ditentukan.',
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

extension on PlaylistTrack {
  bool originalUrlMatch(String otherUrl) {
    return url.trim() == otherUrl.trim();
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
