import 'package:flutter/widgets.dart';

/// App-wide [RouteObserver] wired into [MaterialApp.navigatorObservers] so
/// page layers can react when a route above them pops and they become visible
/// again (e.g. the home continue-watching shelf reloading progress after a
/// detail page or the player closed).
final RouteObserver<ModalRoute<void>> yingjiRouteObserver =
    RouteObserver<ModalRoute<void>>();
