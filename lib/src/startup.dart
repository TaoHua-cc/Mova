import 'dart:async';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'diagnostics/frame_trace.dart';

/// The desktop equivalent of Android's single, centered launch icon.
class MovaStartupGate extends StatefulWidget {
  const MovaStartupGate({
    super.key,
    required this.child,
    this.startup,
    this.minimumDuration = Duration.zero,
  });

  final Widget child;
  final Future<void>? startup;
  final Duration minimumDuration;

  @override
  State<MovaStartupGate> createState() => _MovaStartupGateState();
}

class _MovaStartupGateState extends State<MovaStartupGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_finishStartup());
  }

  Future<void> _finishStartup() async {
    if (widget.startup == null) return;
    await Future.wait<void>([
      widget.startup!.catchError((_) {}),
      if (widget.minimumDuration > Duration.zero)
        Future<void>.delayed(widget.minimumDuration),
    ]);
    if (!mounted) return;
    FrameTrace.mark('shell_ready');
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startup == null || _ready) return widget.child;
    return ColoredBox(
      color: YingjiColors.canvas,
      child: Semantics(
        label: 'Mova 正在启动',
        child: Center(
          child: Image.asset(
            'app/assets/mova-logo.png',
            key: const ValueKey('startup-icon'),
            width: 92,
            height: 92,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}
