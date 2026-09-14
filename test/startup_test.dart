import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/startup.dart';

void main() {
  testWidgets('startup canvas stays visible until initialization completes', (
    tester,
  ) async {
    final startup = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: MovaStartupGate(
          startup: startup.future,
          minimumDuration: Duration.zero,
          child: const Text('首页', key: ValueKey('home')),
        ),
      ),
    );

    expect(find.text('Mova'), findsOneWidget);
    expect(find.byKey(const ValueKey('home')), findsNothing);

    startup.complete();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byKey(const ValueKey('home')), findsOneWidget);
    expect(find.text('Mova'), findsNothing);
  });

  testWidgets('startup failure falls back to the app instead of blocking', (
    tester,
  ) async {
    final startup = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: MovaStartupGate(
          startup: startup.future,
          minimumDuration: Duration.zero,
          child: const Text('首页', key: ValueKey('home')),
        ),
      ),
    );

    startup.completeError(StateError('startup failed'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byKey(const ValueKey('home')), findsOneWidget);
  });

  testWidgets('tests and embedded uses can bypass the startup canvas', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MovaStartupGate(child: Text('首页', key: ValueKey('home'))),
      ),
    );

    expect(find.byKey(const ValueKey('home')), findsOneWidget);
    expect(find.text('Mova'), findsNothing);
  });
}
