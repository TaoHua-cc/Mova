import 'dart:async';

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
    child: SafeArea(
      child: Center(
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, child) {
            final value = Curves.easeInOut.transform(pulse.value);
            return Transform.scale(
              scale: .97 + value * .03,
              child: Opacity(opacity: .78 + value * .22, child: child),
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .12),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x42000000),
                      blurRadius: 30,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: Image.asset(
                  'app/assets/mova-logo.png',
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Mova',
                style: TextStyle(
                  color: YingjiColors.ink,
                  fontSize: 25,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: 88,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: const LinearProgressIndicator(
                    minHeight: 2,
                    color: Colors.white,
                    backgroundColor: Color(0x22FFFFFF),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
