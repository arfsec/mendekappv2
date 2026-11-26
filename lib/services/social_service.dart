import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/schedule.dart';
import 'api_service.dart';
import 'bmkg_weather_service.dart';

class SocialComment {
  final String id;
  final String authorName;
  final String content;
  final bool isAdmin;
  final bool isMine;
  final String createdAt;

  const SocialComment({
    required this.id,
    required this.authorName,
    required this.content,
    this.isAdmin = false,
    this.isMine = false,
    this.createdAt = '',
  });

  factory SocialComment.fromJson(Map<String, dynamic> json) {
    return SocialComment(
      id: (json['id'] as String?) ?? '',
      authorName: (json['author_name'] as String?) ?? 'Kicau Mania',
      content: (json['content'] as String?) ?? '',
      isAdmin: json['is_admin'] == true,
      isMine: json['is_mine'] == true,
      createdAt: (json['created_at'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_name': authorName,
        'content': content,
        'is_admin': isAdmin,
        'is_mine': isMine,
        'created_at': createdAt,
      };
}

class SocialPost {
  final String id;
  final String authorName;
  final String authorRegion;
  final String birdTag;
  final String category;
  final String title;
  final String content;
  final bool pinned;
  final bool isAdmin;
  final int likesCount;
  final bool likedByMe;
  final bool isMine;
  final List<SocialComment> comments;
  final String createdAt;

  const SocialPost({
    required this.id,
    required this.authorName,
    this.authorRegion = '',
    this.birdTag = '',
    this.category = 'info',
    required this.title,
    required this.content,
    this.pinned = false,
    this.isAdmin = false,
    this.likesCount = 0,
    this.likedByMe = false,
    this.isMine = false,
    this.comments = const [],
    this.createdAt = '',
  });

  factory SocialPost.fromJson(Map<String, dynamic> json) {
    final rawComments = json['comments'] as List<dynamic>? ?? const [];
    return SocialPost(
      id: (json['id'] as String?) ?? '',
      authorName: (json['author_name'] as String?) ?? 'Kicau Mania',
      authorRegion: (json['author_region'] as String?) ?? '',
      birdTag: (json['bird_tag'] as String?) ?? '',
      category: (json['category'] as String?) ?? 'info',
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
      pinned: json['pinned'] == true,
      isAdmin: json['is_admin'] == true,
      likesCount: int.tryParse('${json['likes_count'] ?? 0}') ?? 0,
      likedByMe: json['liked_by_me'] == true,
      isMine: json['is_mine'] == true,
      comments: rawComments
          .whereType<Map<String, dynamic>>()
          .map(SocialComment.fromJson)
          .toList(),
      createdAt: (json['created_at'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'author_name': authorName,
        'author_region': authorRegion,
        'bird_tag': birdTag,
        'category': category,
        'title': title,
        'content': content,
        'pinned': pinned,
        'is_admin': isAdmin,
        'likes_count': likesCount,
        'liked_by_me': likedByMe,
        'is_mine': isMine,
        'comments': comments.map((e) => e.toJson()).toList(),
        'created_at': createdAt,
      };
}

class SocialActionResult {
  final bool ok;
  final String message;
  final SocialPost? post;
  final List<SocialPost>? posts;

  const SocialActionResult({
    required this.ok,
    required this.message,
    this.post,
    this.posts,
  });
}

class SocialService {
  SocialService._();
  static final SocialService instance = SocialService._();

  static const String _prefFeedCache = 'mendek_social_feed_cache_v1';
  static const String _prefAutoShareBmkg = 'mendek_social_auto_bmkg_v1';
  static const String _prefLastAutoBmkgDate = 'mendek_social_auto_bmkg_date_v1';

  SharedPreferences? _prefs;
  List<SocialPost> _cachedPosts = const [];
  bool _autoShareBmkg = false;

  List<SocialPost> get cachedPosts => _cachedPosts;
  bool get autoShareBmkg => _autoShareBmkg;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _autoShareBmkg = _prefs?.getBool(_prefAutoShareBmkg) ?? false;
    final rawCache = _prefs?.getString(_prefFeedCache);
    if (rawCache != null && rawCache.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCache) as List<dynamic>;
        _cachedPosts = decoded
            .whereType<Map<String, dynamic>>()
            .map(SocialPost.fromJson)
            .where((p) => p.id.isNotEmpty)
            .toList();
      } catch (_) {}
    }
  }

  Future<void> setAutoShareBmkg(bool enabled) async {
    await init();
    _autoShareBmkg = enabled;
    await _prefs?.setBool(_prefAutoShareBmkg, enabled);
  }

  Future<void> _saveCache(List<SocialPost> posts) async {
    _cachedPosts = posts;
    await _prefs?.setString(
      _prefFeedCache,
      jsonEncode(posts.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<SocialPost>> fetchFeed({String category = 'all'}) async {
    await init();
    try {
      final api = ApiService.instance;
      final params = <String, String>{
        'action': 'social_feed',
        if (api.session?.key.isNotEmpty == true) 'key': api.session!.key,
        if (category != 'all' && category.isNotEmpty) 'category': category,
      };
      final uri = Uri.parse(ApiService.baseUrl).replace(queryParameters: params);
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        if (body['ok'] == true && body['posts'] is List<dynamic>) {
          final list = (body['posts'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(SocialPost.fromJson)
              .where((p) => p.id.isNotEmpty)
              .toList();
          if (category == 'all') {
            await _saveCache(list);
          }
          return list;
        }
      }
    } catch (_) {
      // Gunakan cache offline saat jaringan tidak tersedia
    }
    if (category == 'all') return _cachedPosts;
    return _cachedPosts.where((p) => p.category == category).toList();
  }

  Future<SocialActionResult> createPost({
    required String category,
    required String title,
    required String content,
    String authorRegion = '',
    String birdTag = '',
  }) async {
    await init();
    final api = ApiService.instance;
    final key = api.session?.key ?? '';
    if (key.isEmpty) {
      return const SocialActionResult(
        ok: false,
        message: 'Login Key diperlukan untuk posting ke Komunitas.',
      );
    }
    try {
      final resp = await http
          .post(
            Uri.parse(ApiService.baseUrl),
            body: {
              'action': 'social_create',
              'key': key,
              'device_id': api.deviceId,
              'category': category,
              'title': title.trim(),
              'content': content.trim(),
              'author_region': authorRegion.trim(),
              'bird_tag': birdTag.trim(),
            },
          )
          .timeout(const Duration(seconds: 10));
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['ok'] == true) {
        final created = body['post'] is Map<String, dynamic>
            ? SocialPost.fromJson(body['post'] as Map<String, dynamic>)
            : null;
        if (created != null) {
          await _saveCache([created, ..._cachedPosts]);
        }
        return SocialActionResult(
          ok: true,
          message:
              (body['message'] as String?) ?? 'Info dibagikan ke Komunitas!',
          post: created,
        );
      }
      return SocialActionResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal mengirim info.',
      );
    } catch (_) {
      return const SocialActionResult(
        ok: false,
        message: 'Gagal terhubung ke server. Periksa internet HP Anda.',
      );
    }
  }

  Future<SocialActionResult> toggleLike(String postId) async {
    await init();
    final api = ApiService.instance;
    final key = api.session?.key ?? '';
    if (key.isEmpty) {
      return const SocialActionResult(
        ok: false,
        message: 'Login Key diperlukan.',
      );
    }
    try {
      final resp = await http
          .post(
            Uri.parse(ApiService.baseUrl),
            body: {
              'action': 'social_like',
              'key': key,
              'device_id': api.deviceId,
              'post_id': postId,
            },
          )
          .timeout(const Duration(seconds: 8));
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 &&
          body['ok'] == true &&
          body['post'] is Map<String, dynamic>) {
        final updated =
            SocialPost.fromJson(body['post'] as Map<String, dynamic>);
        final nextList = _cachedPosts
            .map((p) => p.id == updated.id ? updated : p)
            .toList();
        await _saveCache(nextList);
        return SocialActionResult(ok: true, message: 'OK', post: updated);
      }
      return SocialActionResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal menyukai postingan.',
      );
    } catch (_) {
      return const SocialActionResult(
        ok: false,
        message: 'Koneksi bermasalah.',
      );
    }
  }

  Future<SocialActionResult> addComment({
    required String postId,
    required String content,
  }) async {
    await init();
    final api = ApiService.instance;
    final key = api.session?.key ?? '';
    if (key.isEmpty) {
      return const SocialActionResult(
        ok: false,
        message: 'Login Key diperlukan untuk berkomentar.',
      );
    }
    try {
      final resp = await http
          .post(
            Uri.parse(ApiService.baseUrl),
            body: {
              'action': 'social_comment',
              'key': key,
              'device_id': api.deviceId,
              'post_id': postId,
              'content': content.trim(),
            },
          )
          .timeout(const Duration(seconds: 8));
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 &&
          body['ok'] == true &&
          body['post'] is Map<String, dynamic>) {
        final updated =
            SocialPost.fromJson(body['post'] as Map<String, dynamic>);
        final nextList = _cachedPosts
            .map((p) => p.id == updated.id ? updated : p)
            .toList();
        await _saveCache(nextList);
        return SocialActionResult(
          ok: true,
          message: (body['message'] as String?) ?? 'Komentar terkirim.',
          post: updated,
        );
      }
      return SocialActionResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal mengirim komentar.',
      );
    } catch (_) {
      return const SocialActionResult(
        ok: false,
        message: 'Koneksi bermasalah.',
      );
    }
  }

  Future<SocialActionResult> deletePost(String postId) async {
    await init();
    final api = ApiService.instance;
    final key = api.session?.key ?? '';
    if (key.isEmpty) {
      return const SocialActionResult(
        ok: false,
        message: 'Login Key diperlukan.',
      );
    }
    try {
      final resp = await http
          .post(
            Uri.parse(ApiService.baseUrl),
            body: {
              'action': 'social_delete',
              'key': key,
              'device_id': api.deviceId,
              'post_id': postId,
            },
          )
          .timeout(const Duration(seconds: 8));
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200 && body['ok'] == true) {
        final list = (body['posts'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SocialPost.fromJson)
            .toList();
        await _saveCache(list);
        return SocialActionResult(
          ok: true,
          message: (body['message'] as String?) ?? 'Postingan dihapus.',
          posts: list,
        );
      }
      return SocialActionResult(
        ok: false,
        message: (body['message'] as String?) ?? 'Gagal menghapus.',
      );
    } catch (_) {
      return const SocialActionResult(
        ok: false,
        message: 'Koneksi bermasalah.',
      );
    }
  }

  Future<bool> maybeAutoShareTomorrowBmkg(
    BmkgTomorrowSummary summary, {
    String birdTag = '',
  }) async {
    await init();
    if (!_autoShareBmkg || !ApiService.instance.hasValidSession) return false;
    final todayKey =
        '${summary.todayDate.year}-${summary.todayDate.month.toString().padLeft(2, '0')}-${summary.todayDate.day.toString().padLeft(2, '0')}';
    final lastShared = _prefs?.getString(_prefLastAutoBmkgDate) ?? '';
    if (lastShared == todayKey) return false;

    final res = await createPost(
      category: 'cuaca',
      title: buildBmkgShareTitle(summary),
      content: buildBmkgShareBody(summary),
      authorRegion: summary.regionLabel,
      birdTag: birdTag.isNotEmpty ? birdTag : 'Info Cuaca BMKG',
    );
    if (res.ok) {
      await _prefs?.setString(_prefLastAutoBmkgDate, todayKey);
      return true;
    }
    return false;
  }

  String buildBmkgShareTitle(BmkgTomorrowSummary summary) {
    return 'Info Cuaca BMKG Besok (${summary.tomorrowDateLabel}) • ${summary.shortRegion}';
  }

  String buildBmkgShareBody(BmkgTomorrowSummary summary) {
    return 'Prakiraan BMKG untuk wilayah ${summary.regionLabel}:\n'
        '• Suhu besok: ${summary.minTempC}°C – ${summary.maxTempC}°C\n'
        '• Jam Panas/Jemur: ${summary.hotHoursText}\n'
        '• Jam Hujan: ${summary.rainHoursText}\n'
        'Saran rawatan: ${summary.birdCareTip}';
  }

  String buildBmkgSocialShareCaption(
    BmkgTomorrowSummary summary, {
    String appName = 'Mendek Arena',
  }) {
    return '⛅ *${buildBmkgShareTitle(summary)}*\n\n'
        '${buildBmkgShareBody(summary)}\n\n'
        'Dibagikan otomatis dari aplikasi $appName 🐦\n'
        '#MendekArena #KicauMania #InfoCuacaBMKG';
  }

  String buildScheduleShareTitle(Schedule schedule, {String? birdLabel}) {
    final bird = (birdLabel != null && birdLabel.trim().isNotEmpty)
        ? ' (${birdLabel.trim()})'
        : '';
    return 'Pola Masteran: ${schedule.name}$bird';
  }

  String buildScheduleShareBody(Schedule schedule, {String? birdLabel}) {
    final trackCount = schedule.effectiveTracks.length;
    final trackInfo = trackCount > 1
        ? '$trackCount isian berurutan (${schedule.platformLabel})'
        : schedule.platformLabel;
    final ambientInfo = schedule.ambientLabel.isNotEmpty
        ? '\n• Terapi Alam: ${schedule.ambientLabel} (${schedule.ambientVolume}%)'
        : '';
    final birdLine = (birdLabel != null && birdLabel.trim().isNotEmpty)
        ? '• Gacoan: $birdLabel\n'
        : '';
    return '$birdLine• Sumber Suara: $trackInfo\n'
        '• Jam Putar: ${schedule.timeRangeText} (${schedule.formattedDays})\n'
        '• Siklus: ${schedule.intervalSummary}\n'
        '• Fade-In Volume: ${schedule.startVolume}% → ${schedule.targetVolume}% (${schedule.fadeInSeconds} dtk)$ambientInfo';
  }

  String buildScheduleSocialShareCaption(
    Schedule schedule, {
    String? birdLabel,
    String appName = 'Mendek Arena',
  }) {
    return '🐦 *${buildScheduleShareTitle(schedule, birdLabel: birdLabel)}*\n\n'
        '${buildScheduleShareBody(schedule, birdLabel: birdLabel)}\n\n'
        'Jadwal masteran otomatis via $appName.\n'
        '#MendekArena #MasteranBurung #KicauMania';
  }

  String buildPostSocialShareCaption(
    SocialPost post, {
    String appName = 'Mendek Arena',
  }) {
    final regionLine =
        post.authorRegion.isNotEmpty ? '📍 ${post.authorRegion}\n' : '';
    final birdLine = post.birdTag.isNotEmpty ? '🐦 ${post.birdTag}\n' : '';
    return '📢 *${post.title}*\n'
        'Oleh: ${post.authorName}\n'
        '$regionLine$birdLine\n'
        '${post.content}\n\n'
        'Dari Komunitas $appName\n'
        '#MendekArena #KicauMania';
  }

  String formatRelativeTime(String isoString) {
    final dt = DateTime.tryParse(isoString);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'Baru saja';
    if (diff.inMinutes < 60) return '${diff.inMinutes} mnt lalu';
    if (diff.inHours < 24) return '${diff.inHours} jam lalu';
    if (diff.inDays < 7) return '${diff.inDays} hr lalu';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}
