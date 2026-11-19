import 'dart:math' as math;
import 'package:flutter/material.dart';

class CloudHeroBanner extends StatefulWidget {
  final int activeCount;
  final int totalCount;
  final String? nextScheduleLabel;
  final String cycleSummaryLabel;
  final Color accentColor;
  final String heroTitle;
  final String heroSubtitle;
  final bool enableCloudAnim;

  const CloudHeroBanner({
    super.key,
    required this.activeCount,
    required this.totalCount,
    this.nextScheduleLabel,
    this.cycleSummaryLabel = '15m / 5m',
    this.accentColor = const Color(0xFF007AFF),
    this.heroTitle = 'Masteran Burung Otomatis',
    this.heroSubtitle = 'Jadwal Harian, Offline & Anti Layar Mati',
    this.enableCloudAnim = true,
  });

  @override
  State<CloudHeroBanner> createState() => _CloudHeroBannerState();
}

class _CloudHeroBannerState extends State<CloudHeroBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _greetingText() {
    final hour = DateTime.now().hour;
    if (hour >= 3 && hour < 11) return 'Selamat Pagi, Kicau Mania';
    if (hour >= 11 && hour < 15) return 'Selamat Siang, Kicau Mania';
    if (hour >= 15 && hour < 18) return 'Selamat Sore, Kicau Mania';
    return 'Selamat Malam, Kicau Mania';
  }

  @override
  Widget build(BuildContext context) {
    final bool isDefaultBlue = widget.accentColor.value == 0xFF007AFF;
    final List<Color> gradientColors = isDefaultBlue
        ? const [
            Color(0xFF0D2853),
            Color(0xFF1D4ED8),
            Color(0xFF0284C7),
          ]
        : [
            Color.lerp(widget.accentColor, Colors.black, 0.55)!,
            widget.accentColor,
            Color.lerp(widget.accentColor, Colors.white, 0.18)!,
          ];

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        boxShadow: [
          BoxShadow(
            color: widget.accentColor.withAlpha(65),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Stack(
          children: [
            if (widget.enableCloudAnim)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _DriftingCloudsPainter(
                        progress: _controller.value,
                        cloudAlpha: 34,
                      ),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(38),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withAlpha(65),
                          ),
                        ),
                        child: Center(
                          child: widget.activeCount > 0
                              ? const AnimatedSoundWaveIcon(
                                  color: Colors.white,
                                  size: 28,
                                )
                              : const Icon(
                                  Icons.cloud_done_rounded,
                                  color: Colors.white,
                                  size: 30,
                                ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _greetingText(),
                              style: const TextStyle(
                                color: Color(0xFFBAE6FD),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              widget.heroTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (widget.heroSubtitle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.heroSubtitle,
                                style: TextStyle(
                                  color: Colors.white.withAlpha(205),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(30),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withAlpha(42),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.alarm_on_rounded,
                                color: Color(0xFFBAE6FD),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'JADWAL AKTIF',
                                      style: TextStyle(
                                        color: Color(0xFFBAE6FD),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    Text(
                                      '${widget.activeCount} / ${widget.totalCount} Aktif',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(30),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withAlpha(42),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.timelapse_rounded,
                                color: Color(0xFFBAE6FD),
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'SIKLUS JEDA',
                                      style: TextStyle(
                                        color: Color(0xFFBAE6FD),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    Text(
                                      widget.cycleSummaryLabel,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(48),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withAlpha(38),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          color: Color(0xFFBAE6FD),
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.nextScheduleLabel ??
                                '${widget.activeCount} jadwal aktif dari ${widget.totalCount} tersimpan',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AnimatedSoundWaveIcon extends StatefulWidget {
  final Color color;
  final double size;

  const AnimatedSoundWaveIcon({
    super.key,
    required this.color,
    this.size = 24,
  });

  @override
  State<AnimatedSoundWaveIcon> createState() => _AnimatedSoundWaveIconState();
}

class _AnimatedSoundWaveIconState extends State<AnimatedSoundWaveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value * 2 * math.pi;
          final bars = [
            0.40 + 0.55 * ((math.sin(t) + 1) / 2),
            0.35 + 0.65 * ((math.sin(t + 1.4) + 1) / 2),
            0.45 + 0.50 * ((math.sin(t + 2.8) + 1) / 2),
            0.30 + 0.60 * ((math.sin(t + 4.1) + 1) / 2),
          ];
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: bars.map((heightFactor) {
              return Container(
                width: widget.size * 0.16,
                height: widget.size * heightFactor,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(widget.size * 0.1),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class AnimatedCloudRestBackdrop extends StatefulWidget {
  const AnimatedCloudRestBackdrop({super.key});

  @override
  State<AnimatedCloudRestBackdrop> createState() =>
      _AnimatedCloudRestBackdropState();
}

class _AnimatedCloudRestBackdropState extends State<AnimatedCloudRestBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _DriftingCloudsPainter(
            progress: _controller.value,
            cloudAlpha: 22,
          ),
        );
      },
    );
  }
}

class _DriftingCloudsPainter extends CustomPainter {
  final double progress;
  final int cloudAlpha;

  const _DriftingCloudsPainter({
    required this.progress,
    required this.cloudAlpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withAlpha(cloudAlpha)
      ..style = PaintingStyle.fill;

    final subtlePaint = Paint()
      ..color = Colors.white.withAlpha((cloudAlpha * 0.65).round())
      ..style = PaintingStyle.fill;

    final x1 = ((progress * (size.width + 180)) - 90);
    _drawCloud(canvas, Offset(x1, size.height * 0.24), 1.05, paint);

    final x2 = (((progress + 0.45) % 1.0) * (size.width + 200)) - 100;
    _drawCloud(canvas, Offset(x2, size.height * 0.72), 0.85, subtlePaint);

    final x3 = (((progress + 0.75) % 1.0) * (size.width + 160)) - 80;
    _drawCloud(canvas, Offset(x3, size.height * 0.42), 0.65, subtlePaint);
  }

  void _drawCloud(Canvas canvas, Offset center, double scale, Paint paint) {
    final path = Path()
      ..addOval(Rect.fromCircle(
        center: Offset(center.dx - 26 * scale, center.dy + 6 * scale),
        radius: 20 * scale,
      ))
      ..addOval(Rect.fromCircle(
        center: Offset(center.dx, center.dy - 6 * scale),
        radius: 26 * scale,
      ))
      ..addOval(Rect.fromCircle(
        center: Offset(center.dx + 28 * scale, center.dy + 4 * scale),
        radius: 21 * scale,
      ))
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(
          center.dx - 44 * scale,
          center.dy + 2 * scale,
          center.dx + 46 * scale,
          center.dy + 26 * scale,
        ),
        Radius.circular(14 * scale),
      ));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DriftingCloudsPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

Route<T> buildPremiumRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
