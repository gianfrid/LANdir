// Tests for the QR scan route: it must never sit on a silent black screen.
//
// The camera cannot start under `flutter test` (the platform start never
// resolves), so the route stays on its placeholder here. The failure UI is
// therefore exercised directly through ScanErrorView, which is what the
// errorBuilder renders on a device when the camera or permission fails.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landir_app/src/views/qr_scan_view.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('scan route shows a starting-camera placeholder, not a blank box',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: QrScanView()));
    await tester.pump();

    // The regression: MobileScanner's default placeholder is a black
    // ColoredBox, which is indistinguishable from a hang.
    expect(find.text('Starting camera...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MobileScanner),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
    );

    // The progress indicator animates forever, so pump fixed frames rather
    // than pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('permission denial explains how to fix it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanErrorView(
          error: const MobileScannerException(
            errorCode: MobileScannerErrorCode.permissionDenied,
          ),
          onRetry: () {},
        ),
      ),
    ));

    expect(find.textContaining('Camera permission is required'), findsOneWidget);
    expect(find.textContaining('Settings > Apps > LANdir'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('generic camera failure shows the reason and a retry',
      (tester) async {
    var retries = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanErrorView(
          error: const MobileScannerException(
            errorCode: MobileScannerErrorCode.genericError,
            errorDetails: MobileScannerErrorDetails(
              message: 'camera is in use by another app',
            ),
          ),
          onRetry: () => retries++,
        ),
      ),
    ));

    expect(find.textContaining('Could not start the camera'), findsOneWidget);
    expect(find.textContaining('camera is in use by another app'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('manual escape pops the route with no code', (tester) async {
    String? result = 'sentinel';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    body: ScanErrorView(
                      error: const MobileScannerException(
                        errorCode: MobileScannerErrorCode.permissionDenied,
                      ),
                      onRetry: () {},
                    ),
                  ),
                ),
              );
            },
            child: const Text('scan'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add server manually instead'));
    await tester.pumpAndSettle();

    expect(find.text('scan'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('backing out of the scan route closes it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QrScanView()),
            ),
            child: const Text('scan'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('scan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(QrScanView), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(QrScanView), findsNothing);
    expect(find.text('scan'), findsOneWidget);
  });
}
