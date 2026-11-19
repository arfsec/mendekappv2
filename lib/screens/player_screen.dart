import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/api_service.dart';
import '../services/db_service.dart';
import '../services/offline_service.dart';
import '../services/url_helper.dart';
import '../widgets/premium_visuals.dart';

class PlayerScreen extends StatefulWidget {
  final String payload;
  final String? scheduleName;
  final bool isManualPreview;

  const PlayerScreen({
    super.key,
    required this.payload,
    this.scheduleName,
    this.isManualPreview = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  WebViewController? _webViewController;
  VideoPlayerController? _videoController;
  Timer? _countdownTimer;
  Timer? _fadeTimer;

  String _scheduleId = '';
  String _rawUrl = '';
  String _platform = 'youtube';
  String _videoId = '';
  String _platformLabel = 'Video';
  String _embedUrl = '';
  int _endHour = 0;
  int _endMinute = 0;
  int _playMinutes = 0;
  int _pauseMinutes = 0;

  DateTime? _targetEndTime;
  Duration _remaining = Duration.zero;
  bool _isPausedPhase = false;
  int _phaseRemainingSeconds = 0;

  bool _isOfflinePlayback = false;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  bool get _hasInterval => _playMinutes > 0 && _pauseMinutes > 0;
  Color get _accent => ApiService.instance.remoteConfig.accentColor;

  @override
  void initState() {
    super.initState();
    _enterFullScreenAndWakelock();
    _parsePayloadAndSetup();
  }

  Future<void> _enterFullScreenAndWakelock() async {
    await WakelockPlus.enable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _exitFullScreenAndWakelock() async {
    await WakelockPlus.disable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _parsePayloadAndSetup() {
    final parts = widget.payload.split('|');
    if (parts.length < 3) {
      setState(() {
        _hasError = true;
        _isLoading = false;
        _errorMessage = 'Data jadwal tidak valid.';
      });
      return;
    }

    _scheduleId = parts[0];
    _rawUrl = parts[1];
    final timeParts = parts[2].split(':');
    _endHour = int.tryParse(timeParts.isNotEmpty ? timeParts[0] : '0') ?? 0;
    _endMinute = int.tryParse(timeParts.length > 1 ? timeParts[1] : '0') ?? 0;

    bool isTestPayload = false;
    if (parts.length >= 4 && parts[3].contains(':')) {
      final intervalParts = parts[3].split(':');
      _playMinutes = int.tryParse(intervalParts[0]) ?? 0;
      _pauseMinutes = int.tryParse(intervalParts[1]) ?? 0;
    }
    if (parts.length >= 5 && parts[4] == 'TEST') {
      isTestPayload = true;
    }

    final parsed = UrlHelper.parseUrl(_rawUrl);
    if (parsed == null) {
      setState(() {
        _hasError = true;
        _isLoading = false;
        _errorMessage = 'URL video tidak dikenali: $_rawUrl';
      });
      return;
    }

    _platform = parsed.platform;
    _videoId = parsed.videoId;
    _platformLabel = parsed.platformLabel;
    _embedUrl = parsed.embedUrl;

    final now = DateTime.now();
    DateTime candidateEnd = DateTime(
      now.year,
      now.month,
      now.day,
      _endHour,
      _endMinute,
    );

    bool needsDbExpiryCheck = false;
    if (isTestPayload) {
      candidateEnd = now.add(const Duration(minutes: 15));
    } else if (!candidateEnd.isAfter(now)) {
      final hoursPassed = now.difference(candidateEnd).inHours;
      if (widget.isManualPreview || hoursPassed >= 12) {
        candidateEnd = candidateEnd.add(const Duration(days: 1));
      } else {
        needsDbExpiryCheck = true;
      }
    }

    _targetEndTime = candidateEnd;
    _remaining = candidateEnd.isAfter(now)
        ? candidateEnd.difference(now)
        : Duration.zero;
    _isPausedPhase = false;
    _phaseRemainingSeconds = _hasInterval ? _playMinutes * 60 : 0;

    if (!needsDbExpiryCheck) {
      _startCountdownTimer();
    }
    _setupPlayback(parsed, needsDbExpiryCheck: needsDbExpiryCheck);
  }


  Future<String?> _resolveDirectYoutubeStreamUrl(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      if (manifest.muxed.isNotEmpty) {
        return manifest.muxed.withHighestBitrate().url.toString();
      }
      if (manifest.audioOnly.isNotEmpty) {
        return manifest.audioOnly.withHighestBitrate().url.toString();
      }
    } catch (_) {
      return null;
    } finally {
      yt.close();
    }
    return null;
  }

  void _startVolumeFadeInTimer(VideoPlayerController? controller) {
    _fadeTimer?.cancel();
    const double start = 0.10;
    const double target = 0.85;
    final int durationSec = ApiService.instance.remoteConfig.fadeInDefaultSec;
    if (durationSec <= 0) {
      controller?.setVolume(target);
      return;
    }
    controller?.setVolume(start);
    int elapsedMs = 0;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      elapsedMs += 500;
      final double t = (elapsedMs / (durationSec * 1000.0)).clamp(0.0, 1.0);
      final double eased = t * t * (3 - 2 * t);
      final double vol = start + (target - start) * eased;
      controller?.setVolume(vol);
      if (t >= 1.0) timer.cancel();
    });
  }

  Future<void> _setupPlayback(
    ParsedVideoUrl parsed, {
    bool needsDbExpiryCheck = false,
  }) async {
    final sched = _scheduleId.isNotEmpty
        ? await DbService.instance.getScheduleById(_scheduleId)
        : null;

    if (!mounted) return;

    if (needsDbExpiryCheck) {
      final now = DateTime.now();
      bool allowTomorrowEnd = false;
      if (sched != null) {
        final startTotal = sched.startHour * 60 + sched.startMinute;
        final endTotal = sched.endHour * 60 + sched.endMinute;
        final todayStart = DateTime(
          now.year,
          now.month,
          now.day,
          sched.startHour,
          sched.startMinute,
        );
        if (endTotal <= startTotal && !now.isBefore(todayStart)) {
          allowTomorrowEnd = true;
        }
      }
      if (allowTomorrowEnd && _targetEndTime != null) {
        final adjustedEnd = _targetEndTime!.add(const Duration(days: 1));
        setState(() {
          _targetEndTime = adjustedEnd;
          _remaining = adjustedEnd.difference(now);
        });
        _startCountdownTimer();
      } else {
        await _stopAndClose();
        return;
      }
    }

    unawaited(
      ApiService.instance.sendMonitoringPing(
        playingNow: widget.scheduleName ?? '$_platformLabel ($_videoId)',
      ),
    );

    // 1. Cek apakah sudah tersedia file MP4 offline di memori HP
    String? offlinePath;
    final String? localPath = sched?.localFilePath;
    if (localPath != null && await File(localPath).exists()) {
      offlinePath = localPath;
    }
    offlinePath ??= await OfflineService.instance.getExistingLocalPath(_videoId);

    if (!mounted) return;

    if (offlinePath != null) {
      try {
        final controller = VideoPlayerController.file(File(offlinePath));
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
        _startVolumeFadeInTimer(controller);
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _videoController = controller;
          _isOfflinePlayback = true;
          _isLoading = false;
          _hasError = false;
        });
        return;
      } catch (_) {
        // Jika file korup, fallback ke pemutaran online
      }
    }

    // 1b. Native YouTube stream via youtube_explode_dart agar tembus lockscreen
    if (_platform == 'youtube' && _videoId.isNotEmpty) {
      final directUrl = await _resolveDirectYoutubeStreamUrl(_videoId);
      if (directUrl != null && mounted) {
        try {
          final controller = VideoPlayerController.networkUrl(Uri.parse(directUrl));
          await controller.initialize();
          await controller.setLooping(true);
          await controller.play();
          _startVolumeFadeInTimer(controller);
          if (!mounted) {
            await controller.dispose();
            return;
          }
          setState(() {
            _videoController = controller;
            _isOfflinePlayback = true;
            _isLoading = false;
            _hasError = false;
          });
          return;
        } catch (_) {}
      }
    }

    // 2. Jika link TikTok shortlink (vt.tiktok.com), selesaikan redirect lebih dulu
    if (parsed.isShortLink) {
      final resolved = await UrlHelper.resolveUrl(_rawUrl);
      if (!mounted) return;
      if (resolved != null) {
        _videoId = resolved.videoId;
        _embedUrl = resolved.embedUrl;
      }
    }

    _initWebView();
    _loadEmbedVideo();
  }

  void _initWebView() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewControllerCreationParams();
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params);

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted && !_isPausedPhase) {
              setState(() {
                _isLoading = true;
                _hasError = false;
              });
            }
          },
          onPageFinished: (_) {
            if (!_isPausedPhase) {
              unawaited(_injectHtmlVideoLoopFallback());
            }
            if (mounted) {
              setState(() {
                _isLoading = false;
              });
            }
          },
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame == true && mounted && !_isPausedPhase) {
              setState(() {
                _isLoading = false;
                _hasError = true;
                _errorMessage =
                    'Gagal memuat video (${error.description}). Pastikan koneksi internet aktif.';
              });
            }
          },
        ),
      );

    setState(() {
      _webViewController = controller;
    });
  }

  Future<void> _injectHtmlVideoLoopFallback() async {
    final webCtrl = _webViewController;
    if (webCtrl == null) return;
    try {
      await webCtrl.runJavaScript('''
        (function() {
          if (window.__mendekLoopInstalled) return;
          window.__mendekLoopInstalled = true;
          function enforceLoop() {
            var vids = document.querySelectorAll('video');
            for (var i = 0; i < vids.length; i++) {
              var v = vids[i];
              v.loop = true;
              if (!v.dataset.mendekBound) {
                v.dataset.mendekBound = '1';
                v.addEventListener('ended', function() {
                  this.currentTime = 0;
                  this.play().catch(function(){});
                });
              }
              if (v.ended) {
                v.currentTime = 0;
                v.play().catch(function(){});
              }
            }
          }
          enforceLoop();
          setInterval(enforceLoop, 2000);
        })();
      ''');
    } catch (_) {}
  }

  static const String _appOrigin =
      'https://com.mendekarena.mendek_arena_masteran';

  void _loadEmbedVideo() {
    final webCtrl = _webViewController;
    if (webCtrl == null || _embedUrl.isEmpty) return;

    if (_platform == 'youtube' && _videoId.isNotEmpty) {
      final String embedSrc =
          'https://www.youtube.com/embed/$_videoId?autoplay=1&playsinline=1&controls=1&loop=1&playlist=$_videoId&enablejsapi=1&rel=0&origin=$_appOrigin';
      final String html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <meta name="referrer" content="strict-origin-when-cross-origin" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background-color: #000000;
      overflow: hidden;
    }
    iframe {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
    }
  </style>
</head>
<body>
  <iframe
    id="yt-player-frame"
    src="$embedSrc"
    title="Masteran Burung"
    referrerpolicy="strict-origin-when-cross-origin"
    allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
    allowfullscreen>
  </iframe>
  <script src="https://www.youtube.com/iframe_api"></script>
  <script>
    var ytPlayer = null;
    function onYouTubeIframeAPIReady() {
      try {
        ytPlayer = new YT.Player('yt-player-frame', {
          events: {
            onReady: function(event) {
              try {
                event.target.unMute();
                event.target.playVideo();
              } catch (e) {}
            },
            onStateChange: function(event) {
              if (event.data === 0) {
                try {
                  event.target.seekTo(0, true);
                  event.target.playVideo();
                } catch (e) {}
              }
            }
          }
        });
      } catch (e) {}
    }
    setInterval(function() {
      if (ytPlayer && typeof ytPlayer.getPlayerState === 'function') {
        var st = ytPlayer.getPlayerState();
        if (st === 0 || st === 5) {
          try {
            ytPlayer.seekTo(0, true);
            ytPlayer.playVideo();
          } catch (e) {}
        }
      }
    }, 2500);
  </script>
</body>
</html>
''';
      webCtrl.loadHtmlString(html, baseUrl: _appOrigin);
      return;
    }

    if (_platform == 'tiktok' && RegExp(r'^\d+$').hasMatch(_videoId)) {
      final String ttSrc =
          'https://www.tiktok.com/player/v1/$_videoId?autoplay=1&loop=1&controls=1&music_info=0&description=0&rel=0';
      final String ttHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <meta name="referrer" content="strict-origin-when-cross-origin" />
  <style>
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      background-color: #000000;
      overflow: hidden;
    }
    iframe {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      border: 0;
    }
  </style>
</head>
<body>
  <iframe
    id="tt-player-frame"
    src="$ttSrc"
    title="Masteran TikTok"
    referrerpolicy="strict-origin-when-cross-origin"
    allow="autoplay; fullscreen; encrypted-media; picture-in-picture"
    allowfullscreen>
  </iframe>
  <script>
    var ttFrame = document.getElementById('tt-player-frame');
    function sendTtCmd(type, value) {
      if (ttFrame && ttFrame.contentWindow) {
        var payload = { type: type, 'x-tiktok-player': true };
        if (value !== undefined) payload.value = value;
        ttFrame.contentWindow.postMessage(payload, '*');
      }
    }
    window.addEventListener('message', function(ev) {
      try {
        var data = typeof ev.data === 'string' ? JSON.parse(ev.data) : ev.data;
        if (!data || !data['x-tiktok-player']) return;
        if (data.type === 'onPlayerReady') {
          sendTtCmd('unMute');
          sendTtCmd('play');
        } else if (data.type === 'onStateChange' && data.value === 0) {
          sendTtCmd('seekTo', 0);
          sendTtCmd('play');
        }
      } catch (e) {}
    });
  </script>
</body>
</html>
''';
      webCtrl.loadHtmlString(ttHtml, baseUrl: _appOrigin);
      return;
    }

    webCtrl.loadRequest(Uri.parse(_embedUrl));
  }

  void _enterPausePhase() {
    setState(() {
      _isPausedPhase = true;
      _phaseRemainingSeconds = _pauseMinutes * 60;
      _isLoading = false;
      _hasError = false;
    });
    if (_isOfflinePlayback) {
      _videoController?.pause();
    } else {
      _webViewController?.loadHtmlString(
        '<!DOCTYPE html><html><body style="margin:0;background:#000000;"></body></html>',
      );
    }
  }

  void _enterPlayPhase() {
    setState(() {
      _isPausedPhase = false;
      _phaseRemainingSeconds = _hasInterval ? _playMinutes * 60 : 0;
      _isLoading = !_isOfflinePlayback;
      _hasError = false;
    });
    if (_isOfflinePlayback) {
      _videoController?.play();
    } else {
      _loadEmbedVideo();
    }
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _fadeTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _targetEndTime == null) return;
      final diff = _targetEndTime!.difference(DateTime.now());
      if (diff <= Duration.zero) {
        _stopAndClose();
        return;
      }

      if (_hasInterval) {
        if (_phaseRemainingSeconds <= 1) {
          if (_isPausedPhase) {
            setState(() {
              _remaining = diff;
            });
            _enterPlayPhase();
            return;
          } else {
            setState(() {
              _remaining = diff;
            });
            _enterPausePhase();
            return;
          }
        } else {
          setState(() {
            _remaining = diff;
            _phaseRemainingSeconds -= 1;
          });
          return;
        }
      }

      setState(() {
        _remaining = diff;
      });
    });
  }

  Future<void> _stopAndClose() async {
    _countdownTimer?.cancel();
    _fadeTimer?.cancel();
    await _videoController?.pause();
    await _exitFullScreenAndWakelock();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _formatMinutesSeconds(int totalSeconds) {
    final mins = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _fadeTimer?.cancel();
    _videoController?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final endText =
        '${_endHour.toString().padLeft(2, '0')}:${_endMinute.toString().padLeft(2, '0')}';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _stopAndClose();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: const Color(0xFF0F172A),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.scheduleName ?? 'Masteran $_platformLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (_isOfflinePlayback)
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _accent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'OFFLINE',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              Flexible(
                                child: Text(
                                  '$_platformLabel • Selesai jam $endText',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFBAE6FD),
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF38BDF8)),
                      ),
                      child: Text(
                        _formatDuration(_remaining),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_hasInterval)
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: _isPausedPhase ? const Color(0xFFB45309) : _accent,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          if (_isPausedPhase)
                            const Icon(
                              Icons.cloud_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          else
                            const AnimatedSoundWaveIcon(
                              color: Colors.white,
                              size: 18,
                            ),
                          const SizedBox(width: 10),
                          Text(
                            _isPausedPhase
                                ? 'SEDANG JEDA (ISTIRAHAT)'
                                : 'MEMUTAR • Jeda dalam ${_formatMinutesSeconds(_phaseRemainingSeconds)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '$_playMinutes mnt / $_pauseMinutes mnt',
                        style: TextStyle(
                          color: Colors.white.withAlpha(220),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    if (!_hasError &&
                        _isOfflinePlayback &&
                        _videoController != null &&
                        _videoController!.value.isInitialized)
                      Center(
                        child: AspectRatio(
                          aspectRatio: _videoController!.value.aspectRatio,
                          child: VideoPlayer(_videoController!),
                        ),
                      )
                    else if (!_hasError &&
                        _webViewController != null &&
                        _embedUrl.isNotEmpty)
                      WebViewWidget(controller: _webViewController!),
                    if (_isPausedPhase)
                      Stack(
                        children: [
                          Container(
                            width: double.infinity,
                            height: double.infinity,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0xFF070D19),
                                  Color(0xFF0F1E36),
                                  Color(0xFF080E1A),
                                ],
                              ),
                            ),
                          ),
                          const Positioned.fill(
                            child: AnimatedCloudRestBackdrop(),
                          ),
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 96,
                                    height: 96,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF38BDF8)
                                          .withAlpha(32),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF38BDF8)
                                            .withAlpha(110),
                                      ),
                                    ),
                                    child: const Icon(
                                      Icons.cloud_queue_rounded,
                                      size: 52,
                                      color: Color(0xFF7DD3FC),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  const Text(
                                    'Waktu Jeda Istirahat Burung',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Video dihentikan sementara agar burung beristirahat.\nPemutaran akan otomatis dilanjutkan dalam:',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 28,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                          color: const Color(0xFF38BDF8)),
                                    ),
                                    child: Text(
                                      _formatMinutesSeconds(
                                          _phaseRemainingSeconds),
                                      style: const TextStyle(
                                        color: Color(0xFF7DD3FC),
                                        fontSize: 44,
                                        fontWeight: FontWeight.bold,
                                        fontFeatures: [
                                          FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _accent,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 14,
                                      ),
                                    ),
                                    onPressed: _enterPlayPhase,
                                    icon: const Icon(Icons.play_arrow_rounded),
                                    label: const Text(
                                      'Lanjut Putar Sekarang',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_isLoading && !_hasError && !_isPausedPhase)
                      const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 16),
                            Text(
                              'Memuat video masteran...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_hasError && !_isPausedPhase)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.wifi_off_rounded,
                                color: Colors.amber,
                                size: 56,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _errorMessage ?? 'Gagal memuat video.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 20),
                              FilledButton.icon(
                                onPressed: _enterPlayPhase,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Coba Muat Ulang'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Colors.grey.shade900,
                child: Row(
                  children: [
                    if (_hasInterval && !_isPausedPhase) ...[
                      SizedBox(
                        height: 58,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.amber.shade300,
                            side: BorderSide(color: Colors.amber.shade400),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _enterPausePhase,
                          icon: const Icon(Icons.pause_rounded, size: 24),
                          label: const Text(
                            'JEDA',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: SizedBox(
                        height: 58,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _stopAndClose,
                          icon: const Icon(Icons.stop_circle_rounded, size: 28),
                          label: const Text(
                            'STOP MASTERAN',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
