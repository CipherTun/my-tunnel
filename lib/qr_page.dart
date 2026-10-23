import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QrPage extends StatelessWidget {
  const QrPage({super.key, required this.title, required this.data});
  final String title;
  final String data;

  @override
  Widget build(BuildContext context) {
    final tooLong = data.length > 2000;
    return Scaffold(
      appBar: AppBar(title: Text(title, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        if (tooLong)
          const Text('This link is too long for a QR code. Use Export / copy instead.')
        else
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(data: data, version: QrVersions.auto, size: 280),
            ),
          ),
        const SizedBox(height: 16),
        const Text('Contains the server credentials. Share it only with people you trust.',
            style: TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text('Copy link'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: data));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          },
        ),
      ]),
    );
  }
}
