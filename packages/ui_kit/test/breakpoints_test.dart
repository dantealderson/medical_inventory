import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_kit/ui_kit.dart';

void main() {
  group('Breakpoints', () {
    test('classifies phone widths', () {
      expect(Breakpoints.of(320), ScreenSize.phone);
      expect(Breakpoints.of(390), ScreenSize.phone);
      expect(Breakpoints.of(599), ScreenSize.phone);
    });

    test('classifies tablet widths', () {
      expect(Breakpoints.of(600), ScreenSize.tablet);
      expect(Breakpoints.of(1023), ScreenSize.tablet);
    });

    test('classifies desktop widths', () {
      expect(Breakpoints.of(1024), ScreenSize.desktop);
      expect(Breakpoints.of(1920), ScreenSize.desktop);
    });

    test('treats the boundaries as inclusive lower bounds', () {
      expect(Breakpoints.of(Breakpoints.tabletMin), ScreenSize.tablet);
      expect(Breakpoints.of(Breakpoints.desktopMin), ScreenSize.desktop);
      expect(Breakpoints.of(Breakpoints.tabletMin - 1), ScreenSize.phone);
      expect(Breakpoints.of(Breakpoints.desktopMin - 1), ScreenSize.tablet);
    });

    testWidgets('context.screenSize reads the media query width', (tester) async {
      late ScreenSize size;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Builder(
            builder: (context) {
              size = context.screenSize;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(size, ScreenSize.phone);
    });
  });
}
