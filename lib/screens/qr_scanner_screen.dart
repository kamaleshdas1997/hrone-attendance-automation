import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans a TOTP QR code (otpauth://totp/...) and returns the secret.
/// Returns null if cancelled.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _ctrl = MobileScannerController();
  bool _found = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue ?? '';
      if (raw.startsWith('otpauth://')) {
        _found = true;
        final secret = _extractSecret(raw);
        if (secret != null) {
          Navigator.of(context).pop(secret);
        } else {
          setState(() => _error = 'QR found but no secret key inside.\nTry the HROne MFA setup page again.');
          _found = false;
        }
        return;
      }
    }
    // Non-TOTP QR scanned
    setState(() => _error = 'This is not an authenticator QR code.\nPoint at the HROne MFA setup QR.');
  }

  String? _extractSecret(String otpUri) {
    try {
      final uri = Uri.parse(otpUri);
      final secret = uri.queryParameters['secret'];
      if (secret != null && secret.isNotEmpty) return secret.toUpperCase();
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan Authenticator QR'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            tooltip: 'Toggle torch',
            onPressed: () => _ctrl.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera feed
          MobileScanner(
            controller: _ctrl,
            onDetect: _onDetect,
          ),

          // Overlay with cut-out
          _ScanOverlay(),

          // Instructions
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade900,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Text(
                    'Point at the QR code from HROne\'s MFA setup page.\n'
                    'Go to HROne web → Profile → Security → Reset MFA to get it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dark overlay with a square cut-out in the centre
class _ScanOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.maxWidth * 0.65;
      final left = (constraints.maxWidth - size) / 2;
      final top = (constraints.maxHeight - size) / 2 - 40;
      return Stack(
        children: [
          // Dark mask
          ColorFiltered(
            colorFilter: ColorFilter.mode(
                Colors.black.withOpacity(0.55), BlendMode.srcOut),
            child: Stack(
              children: [
                Container(
                    decoration: const BoxDecoration(
                        color: Colors.black,
                        backgroundBlendMode: BlendMode.dstOut)),
                Positioned(
                  left: left,
                  top: top,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Corner brackets
          Positioned(
            left: left,
            top: top,
            child: _Brackets(size: size),
          ),
        ],
      );
    });
  }
}

class _Brackets extends StatelessWidget {
  final double size;
  const _Brackets({required this.size});

  @override
  Widget build(BuildContext context) {
    const t = 3.0; // line thickness
    const l = 24.0; // bracket arm length
    const r = 12.0; // corner radius
    final color = Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _BracketPainter(color: color, t: t, l: l, r: r),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  final Color color;
  final double t, l, r;
  const _BracketPainter(
      {required this.color, required this.t, required this.l, required this.r});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = t
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void corner(double x, double y, double dx, double dy) {
      final path = Path()
        ..moveTo(x, y + dy * l)
        ..lineTo(x, y + dy * r)
        ..arcToPoint(Offset(x + dx * r, y),
            radius: Radius.circular(r), clockwise: dy < 0 == dx > 0)
        ..lineTo(x + dx * l, y);
      canvas.drawPath(path, paint);
    }

    corner(0, 0, 1, 1);
    corner(size.width, 0, -1, 1);
    corner(0, size.height, 1, -1);
    corner(size.width, size.height, -1, -1);
  }

  @override
  bool shouldRepaint(_BracketPainter old) => old.color != color;
}
