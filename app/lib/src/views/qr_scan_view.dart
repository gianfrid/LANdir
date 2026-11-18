// QR scanner for adding a server. Pops with the scanned string, or null if
// the user backs out.
//
// MobileScanner paints a black ColoredBox while the camera initializes and a
// black error box when it fails. Without an explicit errorBuilder a denied
// permission or a busy camera is indistinguishable from a hang, so every
// failure state here is spelled out.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScanView extends StatefulWidget {
  const QrScanView({super.key});

  @override
  State<QrScanView> createState() => _QrScanViewState();
}

class _QrScanViewState extends State<QrScanView> {
  // One controller for the lifetime of the route: the widget's internal
  // controller is disposed and recreated on every rebuild, which can race
  // with the camera session and leave the preview black.
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // Guards against a second pop when several codes arrive in one frame.
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(raw.trim());
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan server QR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flashlight_on),
            tooltip: 'Toggle flashlight',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        placeholderBuilder: (context) => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Starting camera...'),
            ],
          ),
        ),
        errorBuilder: (context, error) => ScanErrorView(
          error: error,
          onRetry: () => _controller.start(),
        ),
      ),
    );
  }
}

/// Camera failure UI: says what went wrong and offers a way out.
///
/// Public (and not private like the rest of this file) only so tests can
/// construct it directly — the camera start never resolves under
/// `flutter test`, so the errorBuilder path is unreachable in widget tests.
/// Do not use it from other libraries; the scanner route is its only
/// in-app consumer.
@visibleForTesting
class ScanErrorView extends StatelessWidget {
  const ScanErrorView({super.key, required this.error, required this.onRetry});

  final MobileScannerException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = denied
        ? 'Camera permission is required to scan a QR code.\n\n'
            'Grant it in Settings > Apps > LANdir > Permissions, then retry.'
        : 'Could not start the camera.\n\n${error.errorDetails?.message ?? error.errorCode.message}';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 48),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Add server manually instead'),
            ),
          ],
        ),
      ),
    );
  }
}
