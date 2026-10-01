import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../brand.dart';
import '../platform/window_host.dart';

/// Cache a shelf only during short outer scrolling, never during its own
/// horizontal browsing. Flutter owns and releases the snapshot texture.
class ScrollSnapshot extends StatefulWidget {
  const ScrollSnapshot({super.key, required this.child});
  final Widget child;

  @override
  State<ScrollSnapshot> createState() => _ScrollSnapshotState();
}

class _ScrollSnapshotState extends State<ScrollSnapshot> {
  final _controller = SnapshotController();
  bool _horizontal = false;

  @override
  void initState() {
    super.initState();
    yingjiScrollInProgress.addListener(_sync);
    _sync();
  }

  void _sync() {
    final wasSnapshotting = _controller.allowSnapshotting;
    _controller.allowSnapshotting =
        WindowHost.isDesktop && yingjiScrollInProgress.value && !_horizontal;
    if (wasSnapshotting && !_controller.allowSnapshotting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) RendererBinding.instance.mouseTracker.updateAllDevices();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  @override
  void dispose() {
    yingjiScrollInProgress.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !WindowHost.isDesktop
      ? widget.child
      : NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.axis == Axis.horizontal) {
              if (notification is ScrollStartNotification) _horizontal = true;
              if (notification is ScrollEndNotification) _horizontal = false;
              _sync();
            }
            return false;
          },
          child: SnapshotWidget(
            controller: _controller,
            mode: SnapshotMode.permissive,
            autoresize: true,
            child: widget.child,
          ),
        );
}
