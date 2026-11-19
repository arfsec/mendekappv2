import 'package:http/http.dart' as http;

class ParsedVideoUrl {
  final String platform; // 'youtube' atau 'tiktok'
  final String videoId;
  final String originalUrl;
  final String embedUrl;
  final bool isShortLink;

  const ParsedVideoUrl({
    required this.platform,
    required this.videoId,
    required this.originalUrl,
    required this.embedUrl,
    this.isShortLink = false,
  });

  String get platformLabel => platform == 'tiktok' ? 'TikTok' : 'YouTube';
}

class UrlHelper {
  static final RegExp _youtubeShortRegex = RegExp(
    r'^https?:\/\/(?:www\.)?youtu\.be\/([A-Za-z0-9_-]{6,})',
    caseSensitive: false,
  );

  static final RegExp _youtubeWatchRegex = RegExp(
    r'^https?:\/\/(?:www\.|m\.|music\.)?youtube\.com\/watch\?(?:.*&)?v=([A-Za-z0-9_-]{6,})',
    caseSensitive: false,
  );

  static final RegExp _youtubePathRegex = RegExp(
    r'^https?:\/\/(?:www\.|m\.)?youtube\.com\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{6,})',
    caseSensitive: false,
  );

  static final RegExp _tiktokVideoRegex = RegExp(
    r'^https?:\/\/(?:www\.|m\.)?tiktok\.com\/(?:@[^\/\s]+\/)?video\/(\d+)',
    caseSensitive: false,
  );

  static final RegExp _tiktokShortRegex = RegExp(
    r'^https?:\/\/(?:vt\.tiktok\.com|vm\.tiktok\.com|(?:www\.|m\.)?tiktok\.com\/t)\/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );

  static ParsedVideoUrl? parseUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;

    final normalized =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
            ? trimmed
            : 'https://$trimmed';

    final ytShort = _youtubeShortRegex.firstMatch(normalized);
    if (ytShort != null && ytShort.group(1) != null) {
      final id = ytShort.group(1)!;
      return ParsedVideoUrl(
        platform: 'youtube',
        videoId: id,
        originalUrl: normalized,
        embedUrl: buildEmbedUrl('youtube', id),
      );
    }

    final ytWatch = _youtubeWatchRegex.firstMatch(normalized);
    if (ytWatch != null && ytWatch.group(1) != null) {
      final id = ytWatch.group(1)!;
      return ParsedVideoUrl(
        platform: 'youtube',
        videoId: id,
        originalUrl: normalized,
        embedUrl: buildEmbedUrl('youtube', id),
      );
    }

    final ytPath = _youtubePathRegex.firstMatch(normalized);
    if (ytPath != null && ytPath.group(1) != null) {
      final id = ytPath.group(1)!;
      return ParsedVideoUrl(
        platform: 'youtube',
        videoId: id,
        originalUrl: normalized,
        embedUrl: buildEmbedUrl('youtube', id),
      );
    }

    final ttMatch = _tiktokVideoRegex.firstMatch(normalized);
    if (ttMatch != null && ttMatch.group(1) != null) {
      final id = ttMatch.group(1)!;
      return ParsedVideoUrl(
        platform: 'tiktok',
        videoId: id,
        originalUrl: normalized,
        embedUrl: buildEmbedUrl('tiktok', id),
      );
    }

    final ttShort = _tiktokShortRegex.firstMatch(normalized);
    if (ttShort != null && ttShort.group(1) != null) {
      final code = ttShort.group(1)!;
      return ParsedVideoUrl(
        platform: 'tiktok',
        videoId: code,
        originalUrl: normalized,
        embedUrl: normalized,
        isShortLink: true,
      );
    }

    return null;
  }

  static Future<ParsedVideoUrl?> resolveUrl(String rawUrl) async {
    final initial = parseUrl(rawUrl);
    if (initial == null || !initial.isShortLink) {
      return initial;
    }

    final client = http.Client();
    try {
      String currentUrl = initial.originalUrl;
      for (int hop = 0; hop < 5; hop++) {
        final uri = Uri.tryParse(currentUrl);
        if (uri == null) break;

        final req = http.Request('GET', uri)..followRedirects = false;
        req.headers['User-Agent'] =
            'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
        req.headers['Accept'] =
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

        final streamed = await client.send(req).timeout(
              const Duration(seconds: 8),
            );
        final location = streamed.headers['location'];
        if (location != null && location.isNotEmpty) {
          final nextUri = uri.resolve(location);
          currentUrl = nextUri.toString();

          final resolvedMatch = _tiktokVideoRegex.firstMatch(currentUrl);
          if (resolvedMatch != null && resolvedMatch.group(1) != null) {
            final id = resolvedMatch.group(1)!;
            return ParsedVideoUrl(
              platform: 'tiktok',
              videoId: id,
              originalUrl: currentUrl,
              embedUrl: buildEmbedUrl('tiktok', id),
              isShortLink: false,
            );
          }
          continue;
        }

        // Cek body HTML apabila canonical / videoId disematkan tanpa redirect HTTP
        final body = await streamed.stream.bytesToString();
        final bodyMatch = RegExp(
          r'https?:\/\/(?:www\.|m\.)?tiktok\.com\/(?:@[^\/\s"\\]+\/)?video\/(\d+)',
          caseSensitive: false,
        ).firstMatch(body);
        if (bodyMatch != null && bodyMatch.group(1) != null) {
          final id = bodyMatch.group(1)!;
          return ParsedVideoUrl(
            platform: 'tiktok',
            videoId: id,
            originalUrl: bodyMatch.group(0)!,
            embedUrl: buildEmbedUrl('tiktok', id),
            isShortLink: false,
          );
        }
        break;
      }
    } catch (_) {
      // Abaikan error jaringan & fallback memuat URL shortlink langsung di WebView
    } finally {
      client.close();
    }

    return initial;
  }

  static String? validateUrl(String? rawUrl) {
    final value = (rawUrl ?? '').trim();
    if (value.isEmpty) {
      return 'Link video YouTube atau TikTok wajib diisi.';
    }
    final normalized = value.startsWith('http://') || value.startsWith('https://')
        ? value
        : 'https://$value';

    if (parseUrl(normalized) == null) {
      return 'Link harus berasal dari YouTube (watch, youtu.be, shorts) atau TikTok (vt.tiktok.com, @user/video/ID).';
    }
    return null;
  }

  static String buildEmbedUrl(String platform, String videoId) {
    if (platform == 'tiktok') {
      return 'https://www.tiktok.com/player/v1/$videoId?autoplay=1&loop=1&controls=1&rel=0';
    }
    return 'https://www.youtube.com/embed/$videoId?autoplay=1&playsinline=1&controls=1&loop=1&playlist=$videoId&enablejsapi=1&rel=0';
  }
}
