import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'brand.dart';

/// Keeps startup work behind a real, lightweight first frame instead of
/// exposing an unpainted window. The indicator is intentionally indeterminate:
/// startup has no truthful percentage to display.
class MovaStartupGate extends StatefulWidget {
  const MovaStartupGate({
    super.key,
    required this.child,
    this.startup,
    this.minimumDuration = const Duration(milliseconds: 720),
  });

  final Widget child;
  final Future<void>? startup;
  final Duration minimumDuration;

  @override
  State<MovaStartupGate> createState() => _MovaStartupGateState();
}

class _MovaStartupGateState extends State<MovaStartupGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    )..repeat(reverse: true);
    unawaited(_finishStartup());
  }

  Future<void> _finishStartup() async {
    if (widget.startup == null) {
      _ready = true;
      return;
    }
    await Future.wait<void>([
      widget.startup!.catchError((_) {}),
      Future<void>.delayed(widget.minimumDuration),
    ]);
    if (!mounted) return;
    _pulse.stop();
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startup == null) return widget.child;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: .985, end: 1).animate(animation),
          child: child,
        ),
      ),
      child: _ready
          ? KeyedSubtree(key: const ValueKey('app'), child: widget.child)
          : _StartupCanvas(key: const ValueKey('startup'), pulse: _pulse),
    );
  }
}

class _StartupCanvas extends StatelessWidget {
  const _StartupCanvas({super.key, required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: YingjiColors.canvas,
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          final phase = pulse.value;
          final breath = Curves.easeInOutSine.transform(
            phase <= .5 ? phase * 2 : (1 - phase) * 2,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -.12),
                    radius: .92,
                    colors: [Color(0xFF1A1D24), Color(0xFF080A0E)],
                    stops: [0, .72],
                  ),
                ),
              ),
              CustomPaint(painter: _StartupAtmospherePainter(phase)),
              SafeArea(
                child: Semantics(
                  label: 'Mova 正在启动',
                  child: Center(
                    child: Transform.translate(
                      offset: Offset(0, 3 - breath * 3),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 154,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Transform.rotate(
                                  angle: phase * math.pi * 2,
                                  child: CustomPaint(
                                    size: const Size.square(142),
                                    painter: _StartupOrbitPainter(),
                                  ),
                                ),
                                Container(
                                  width: 92,
                                  height: 92,
                                  padding: const EdgeInsets.all(17),
                                  decoration: BoxDecoration(
                                    color: Color.lerp(
                                      const Color(0x14FFFFFF),
                                      const Color(0x20FFFFFF),
                                      breath,
                                    ),
                                    borderRadius: BorderRadius.circular(31),
                                    border: Border.all(
                                      color: Color.lerp(
                                        const Color(0x20FFFFFF),
                                        const Color(0x42FFFFFF),
                                        breath,
                                      )!,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color.fromRGBO(
                                          255,
                                          255,
                                          255,
                                          .05 + breath * .045,
                                        ),
                                        blurRadius: 34 + breath * 12,
                                        spreadRadius: breath * 2,
                                      ),
                                      const BoxShadow(
                                        color: Color(0x66000000),
                                        blurRadius: 34,
                                        offset: Offset(0, 18),
                                      ),
                                    ],
                                  ),
                                  child: Image.asset(
                                    'app/assets/mova-logo.png',
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Mova',
                            style: TextStyle(
                              color: YingjiColors.ink,
                              fontSize: 29,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 7),
                          const Text(
                            '光影，归于此刻',
                            style: TextStyle(
                              color: Color(0x99FFFFFF),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 3.2,
                            ),
                          ),
                          const SizedBox(height: 30),
                          CustomPaint(
                            size: const Size(112, 3),
                            painter: _StartupSweepPainter(phase),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _StartupAtmospherePainter extends CustomPainter {
  const _StartupAtmospherePainter(this.phase);

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .5, size.height * .46);
    final radius = math.min(size.width, size.height) * (.2 + phase * .015);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0x14FFFFFF), Color(0x00FFFFFF)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glow);

    final line = Paint()
      ..color = const Color(0x0CFFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width * .12, center.dy),
      Offset(size.width * .88, center.dy),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _StartupAtmospherePainter oldDelegate) =>
      oldDelegate.phase != phase;
}

class _StartupOrbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x16FFFFFF);
    final light = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.4
      ..shader = const SweepGradient(
        colors: [Color(0x00FFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)],
        stops: [0, .22, .48],
      ).createShader(rect);
    canvas.drawOval(rect.deflate(8), track);
    canvas.drawArc(rect.deflate(8), -.7, math.pi * 1.25, false, light);
  }

  @override
  bool shouldRepaint(covariant _StartupOrbitPainter oldDelegate) => false;
}

class _StartupSweepPainter extends CustomPainter {
  const _StartupSweepPainter(this.phase);

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(track, Paint()..color = const Color(0x18FFFFFF));
    final width = size.width * .34;
    final left = (size.width + width) * phase - width;
    canvas.save();
    canvas.clipRRect(track);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, 0, width, size.height),
        radius,
      ),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(Rect.fromLTWH(left, 0, width, size.height)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StartupSweepPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
