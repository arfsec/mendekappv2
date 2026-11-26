import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

class LiveModuleWebViewScreen extends StatefulWidget {
  final String title;
  final String url;
  final Color accentColor;

  const LiveModuleWebViewScreen({
    super.key,
    required this.title,
    required this.url,
    required this.accentColor,
  });

  @override
  State<LiveModuleWebViewScreen> createState() =>
      _LiveModuleWebViewScreenState();
}

class _LiveModuleWebViewScreenState extends State<LiveModuleWebViewScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewControllerCreationParams();
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params);
    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
    }

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress = p);
          },
          onWebResourceError: (_) {
            if (!mounted) return;
            setState(() => _hasError = true);
          },
          onNavigationRequest: (req) {
            final uri = Uri.tryParse(req.url);
            if (uri == null || uri.scheme.toLowerCase() != 'https') {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    final initialUri = Uri.tryParse(widget.url.trim());
    if (initialUri != null && initialUri.scheme.toLowerCase() == 'https') {
      controller.loadRequest(initialUri);
    } else {
      _hasError = true;
    }
    _controller = controller;
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        title: Text(
          widget.title,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: () {
              setState(() => _hasError = false);
              _controller.reload();
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Buka di Browser',
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress / 100.0,
                  minHeight: 3,
                  color: widget.accentColor,
                  backgroundColor: const Color(0xFFE5E7EB),
                ),
              )
            : null,
      ),
      body: _hasError
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 48,
                      color: widget.accentColor,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Halaman fitur live gagal dimuat.',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: widget.accentColor,
                      ),
                      onPressed: () {
                        setState(() => _hasError = false);
                        _controller.reload();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Coba Lagi'),
                    ),
                  ],
                ),
              ),
            )
          : WebViewWidget(controller: _controller),
    );
  }
}
