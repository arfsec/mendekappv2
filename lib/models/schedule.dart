import 'dart:convert';

class PlaylistTrack {
  final String id;
  final String title;
  final String url;
  final String platform; // 'youtube', 'tiktok', atau 'local'
  final String videoId;
  final String? localFilePath;

  const PlaylistTrack({
    required this.id,
    required this.title,
    required this.url,
    required this.platform,
    required this.videoId,
    this.localFilePath,
  });

  String get platformLabel {
    if (platform == 'tiktok') return 'TikTok';
    if (platform == 'local') return 'File HP';
    return 'YouTube';
  }

  bool get hasLocalFile =>
      localFilePath != null && localFilePath!.trim().isNotEmpty;

  PlaylistTrack copyWith({
    String? id,
    String? title,
    String? url,
    String? platform,
    String? videoId,
    String? localFilePath,
    bool clearLocalFilePath = false,
  }) {
    return PlaylistTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      url: url ?? this.url,
      platform: platform ?? this.platform,
      videoId: videoId ?? this.videoId,
      localFilePath:
          clearLocalFilePath ? null : (localFilePath ?? this.localFilePath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'platform': platform,
        'video_id': videoId,
        'local_file_path': localFilePath,
      };

  factory PlaylistTrack.fromJson(Map<String, dynamic> json) {
    return PlaylistTrack(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? 'Masteran',
      url: (json['url'] as String?) ?? '',
      platform: (json['platform'] as String?) ?? 'youtube',
      videoId: (json['video_id'] as String?) ?? '',
      localFilePath: json['local_file_path'] as String?,
    );
  }
}

class BirdProfile {
  final String id;
  final String name;
  final String species;
  final String mode; // 'Harian', 'Setting Lomba', 'Mabung', 'Pemulihan'

  const BirdProfile({
    required this.id,
    required this.name,
    this.species = 'Murai Batu',
    this.mode = 'Harian',
  });

  BirdProfile copyWith({
    String? id,
    String? name,
    String? species,
    String? mode,
  }) {
    return BirdProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      species: species ?? this.species,
      mode: mode ?? this.mode,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'species': species,
        'mode': mode,
      };

  factory BirdProfile.fromJson(Map<String, dynamic> json) {
    return BirdProfile(
      id: (json['id'] as String?) ?? 'bird_default',
      name: ((json['name'] as String?) ?? '').trim().isNotEmpty
          ? (json['name'] as String).trim()
          : 'Murai Petir',
      species: ((json['species'] as String?) ?? '').trim().isNotEmpty
          ? (json['species'] as String).trim()
          : 'Murai Batu',
      mode: ((json['mode'] as String?) ?? '').trim().isNotEmpty
          ? (json['mode'] as String).trim()
          : 'Harian',
    );
  }
}

class Schedule {
  final String id;
  final String name;
  final String url;
  final String platform; // 'youtube', 'tiktok', atau 'local'
  final String videoId;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final List<int> days; // 1 = Senin .. 7 = Minggu
  final bool isActive;
  final int createdAt;
  final int playMinutes; // 0 = nonstop tanpa jeda
  final int pauseMinutes; // 0 = tidak ada jeda
  final String? localFilePath; // Path file MP4/MP3 lokal atau offline
  final String birdId;
  final List<PlaylistTrack> tracks;
  final int startVolume; // 0..100
  final int targetVolume; // 5..100
  final int fadeInSeconds; // 0..120
  final String ambientTherapy; // 'none', 'water', 'rain', 'forest'
  final int ambientVolume; // 5..100
  final bool batteryGuardEnabled;

  const Schedule({
    required this.id,
    required this.name,
    required this.url,
    required this.platform,
    required this.videoId,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.days,
    required this.isActive,
    required this.createdAt,
    this.playMinutes = 15,
    this.pauseMinutes = 5,
    this.localFilePath,
    this.birdId = 'bird_default',
    this.tracks = const [],
    this.startVolume = 10,
    this.targetVolume = 85,
    this.fadeInSeconds = 25,
    this.ambientTherapy = 'none',
    this.ambientVolume = 20,
    this.batteryGuardEnabled = true,
  });

  bool get hasInterval => playMinutes > 0 && pauseMinutes > 0;

  List<PlaylistTrack> get effectiveTracks {
    if (tracks.isNotEmpty) return tracks;
    return [
      PlaylistTrack(
        id: '${id}_primary',
        title: name,
        url: url,
        platform: platform,
        videoId: videoId,
        localFilePath: localFilePath,
      ),
    ];
  }

  bool get isOfflineReady =>
      platform == 'local' ||
      (localFilePath != null && localFilePath!.trim().isNotEmpty) ||
      effectiveTracks.any((t) => t.platform == 'local' || t.hasLocalFile);

  String get formattedStartTime =>
      '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}';

  String get formattedEndTime =>
      '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}';

  String get timeRangeText => '$formattedStartTime - $formattedEndTime';

  String get platformLabel {
    if (platform == 'tiktok') return 'TikTok';
    if (platform == 'local') return 'File HP';
    return 'YouTube';
  }

  String get ambientLabel {
    switch (ambientTherapy) {
      case 'water':
        return 'Air Mengalir';
      case 'rain':
        return 'Hujan Ringan';
      case 'forest':
        return 'Hutan Pagi';
      default:
        return '';
    }
  }

  String get intervalSummary => hasInterval
      ? 'Putar $playMinutes mnt • Jeda $pauseMinutes mnt'
      : 'Putar nonstop tanpa jeda';

  String get payload =>
      '$id|$url|$formattedEndTime|$playMinutes:$pauseMinutes';

  String get formattedDays {
    if (days.isEmpty) return 'Tidak ada hari';
    final sorted = [...days]..sort();
    if (sorted.length == 7) return 'Setiap Hari';
    if (sorted.length == 5 &&
        sorted.contains(1) &&
        sorted.contains(2) &&
        sorted.contains(3) &&
        sorted.contains(4) &&
        sorted.contains(5)) {
      return 'Senin - Jumat';
    }
    if (sorted.length == 2 && sorted.contains(6) && sorted.contains(7)) {
      return 'Sabtu & Minggu';
    }
    const labels = <int, String>{
      1: 'Sen',
      2: 'Sel',
      3: 'Rab',
      4: 'Kam',
      5: 'Jum',
      6: 'Sab',
      7: 'Min',
    };
    return sorted
        .map((d) => labels[d] ?? '')
        .where((s) => s.isNotEmpty)
        .join(', ');
  }

  Schedule copyWith({
    String? id,
    String? name,
    String? url,
    String? platform,
    String? videoId,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    List<int>? days,
    bool? isActive,
    int? createdAt,
    int? playMinutes,
    int? pauseMinutes,
    String? localFilePath,
    bool clearLocalFilePath = false,
    String? birdId,
    List<PlaylistTrack>? tracks,
    int? startVolume,
    int? targetVolume,
    int? fadeInSeconds,
    String? ambientTherapy,
    int? ambientVolume,
    bool? batteryGuardEnabled,
  }) {
    return Schedule(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      platform: platform ?? this.platform,
      videoId: videoId ?? this.videoId,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      endHour: endHour ?? this.endHour,
      endMinute: endMinute ?? this.endMinute,
      days: days ?? this.days,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      playMinutes: playMinutes ?? this.playMinutes,
      pauseMinutes: pauseMinutes ?? this.pauseMinutes,
      localFilePath:
          clearLocalFilePath ? null : (localFilePath ?? this.localFilePath),
      birdId: birdId ?? this.birdId,
      tracks: tracks ?? this.tracks,
      startVolume: startVolume ?? this.startVolume,
      targetVolume: targetVolume ?? this.targetVolume,
      fadeInSeconds: fadeInSeconds ?? this.fadeInSeconds,
      ambientTherapy: ambientTherapy ?? this.ambientTherapy,
      ambientVolume: ambientVolume ?? this.ambientVolume,
      batteryGuardEnabled: batteryGuardEnabled ?? this.batteryGuardEnabled,
    );
  }

  Map<String, dynamic> toMap() {
    final sortedDays = [...days]..sort();
    return {
      'id': id,
      'name': name,
      'url': url,
      'platform': platform,
      'video_id': videoId,
      'start_hour': startHour,
      'start_minute': startMinute,
      'end_hour': endHour,
      'end_minute': endMinute,
      'days': sortedDays.join(','),
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt,
      'play_minutes': playMinutes,
      'pause_minutes': pauseMinutes,
      'local_file_path': localFilePath,
      'bird_id': birdId,
      'tracks_json': jsonEncode(tracks.map((t) => t.toJson()).toList()),
      'start_volume': startVolume,
      'target_volume': targetVolume,
      'fade_in_seconds': fadeInSeconds,
      'ambient_therapy': ambientTherapy,
      'ambient_volume': ambientVolume,
      'battery_guard_enabled': batteryGuardEnabled ? 1 : 0,
    };
  }

  factory Schedule.fromMap(Map<String, dynamic> map) {
    final rawDays = (map['days'] as String? ?? '').trim();
    final parsedDays = rawDays.isEmpty
        ? <int>[]
        : rawDays
            .split(',')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .where((d) => d >= 1 && d <= 7)
            .toList();

    List<PlaylistTrack> parsedTracks = const [];
    final rawTracks = map['tracks_json'] as String?;
    if (rawTracks != null && rawTracks.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTracks);
        if (decoded is List) {
          parsedTracks = decoded
              .whereType<Map<String, dynamic>>()
              .map(PlaylistTrack.fromJson)
              .where((t) => t.url.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }

    final rawBirdId = (map['bird_id'] as String? ?? '').trim();
    final rawTherapy = (map['ambient_therapy'] as String? ?? '').trim();

    return Schedule(
      id: map['id'] as String,
      name: map['name'] as String,
      url: map['url'] as String,
      platform: map['platform'] as String,
      videoId: map['video_id'] as String,
      startHour: map['start_hour'] as int,
      startMinute: map['start_minute'] as int,
      endHour: map['end_hour'] as int,
      endMinute: map['end_minute'] as int,
      days: parsedDays,
      isActive: (map['is_active'] as int) == 1,
      createdAt: map['created_at'] as int,
      playMinutes: (map['play_minutes'] as int?) ?? 15,
      pauseMinutes: (map['pause_minutes'] as int?) ?? 5,
      localFilePath: map['local_file_path'] as String?,
      birdId: rawBirdId.isNotEmpty ? rawBirdId : 'bird_default',
      tracks: parsedTracks,
      startVolume: ((map['start_volume'] as int?) ?? 10).clamp(0, 100),
      targetVolume: ((map['target_volume'] as int?) ?? 85).clamp(5, 100),
      fadeInSeconds: ((map['fade_in_seconds'] as int?) ?? 25).clamp(0, 120),
      ambientTherapy: rawTherapy.isNotEmpty ? rawTherapy : 'none',
      ambientVolume: ((map['ambient_volume'] as int?) ?? 20).clamp(5, 100),
      batteryGuardEnabled:
          map['battery_guard_enabled'] == null ? true : (map['battery_guard_enabled'] as int) == 1,
    );
  }
}
