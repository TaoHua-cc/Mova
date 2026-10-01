import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/motion.dart';

void main() {
  testWidgets(
    'list optional work waits for entry and cancels on quick return',
    (tester) async {
      var runs = 0;
      late BuildContext root;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              root = context;
              return const Scaffold();
            },
          ),
        ),
      );
      MovaListRoute<void> open() => MovaListRoute<void>(
        builder: (context) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await MovaMotion.afterPageTransition(context);
            if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
              runs++;
            }
          });
          return const Scaffold(body: Text('list'));
        },
      );
      Navigator.of(root).push(open());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(runs, 0);
      await tester.pumpAndSettle();
      expect(runs, 1);
      Navigator.of(root).pop();
      await tester.pumpAndSettle();
      runs = 0;
      Navigator.of(root).push(open());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      Navigator.of(root).pop();
      await tester.pumpAndSettle();
      expect(runs, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('app decorative tickers pause outside foreground and resume', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: MovaLifecycleScope(
          child: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(TickerMode.valuesOf(context).enabled, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(TickerMode.valuesOf(context).enabled, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(TickerMode.valuesOf(context).enabled, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
