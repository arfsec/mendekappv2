class Schedule {
  final String id;
  final String name;
  final String url;
  final String platform; // 'youtube' atau 'tiktok'
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
  final String? localFilePath; // Path file MP4 hasil download offline

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
  });

  bool get hasInterval => playMinutes > 0 && pauseMinutes > 0;
  bool get isOfflineReady =>
      localFilePath != null && localFilePath!.trim().isNotEmpty;

  String get formattedStartTime =>
      '${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}';

  String get formattedEndTime =>
      '${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}';

  String get timeRangeText => '$formattedStartTime - $formattedEndTime';

  String get platformLabel => platform == 'tiktok' ? 'TikTok' : 'YouTube';

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
    );
  }
}
