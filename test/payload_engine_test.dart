import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xray_vpn/payload_engine.dart';

void main() {
  group('payload expansion', () {
    test('expands host, port, protocol and line-ending tokens', () {
      final result = expandPayload('[method] [host]:[port] [protocol][crlf]Host: [sni][crlf*2]', host: 'ssh.example', port: 443, sni: 'front.example');
      expect(utf8.decode(result.chunks.expand((e) => e).toList()), 'CONNECT ssh.example:443 HTTP/1.1\r\nHost: front.example\r\n\r\n');
      expect(result.raw, isFalse);
    });

    test('raw payload bypasses HTTP response parsing', () {
      final result = expandPayload('[raw]SSH-2.0-client\r\n', host: 'server', port: 22);
      expect(result.raw, isTrue);
      expect(utf8.decode(result.chunks.single), 'SSH-2.0-client\r\n');
    });

    test('delay-split marker creates multiple writes with a pause', () {
      final result = expandPayload('first[delay_split]second', host: 'server', port: 22);
      expect(result.chunks, hasLength(2));
      expect(result.delay, const Duration(milliseconds: 250));
    });

    test('custom delay is parsed', () {
      final result = expandPayload('first[split]second[delay:400]', host: 'server', port: 22);
      expect(result.delay, const Duration(milliseconds: 400));
    });
  });
}
