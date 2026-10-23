import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/models.dart';
import 'package:vpn/subscription.dart';

void main() {
  const a = 'vless://u@a.example:443?type=ws#Server%20A';
  const b = 'trojan://pw@b.example:443#B';

  test('plain subscription body', () {
    expect(parseSubscriptionBody('$a\n$b\nnot a link\n'), [a, b]);
  });

  test('base64 subscription body (standard and url-safe, unpadded)', () {
    final raw = '$a\n$b';
    expect(parseSubscriptionBody(base64.encode(utf8.encode(raw))), [a, b]);
    expect(
        parseSubscriptionBody(base64Url.encode(utf8.encode(raw)).replaceAll('=', '')), [a, b]);
  });

  test('empty or junk body gives no links', () {
    expect(parseSubscriptionBody(''), isEmpty);
    expect(parseSubscriptionBody('<html>nope</html>'), isEmpty);
  });

  test('link names', () {
    expect(shareLinkName(a), 'Server A');
    final vm = 'vmess://${base64.encode(utf8.encode(jsonEncode({'ps': 'My VM', 'add': 'x'})))}';
    expect(shareLinkName(vm), 'My VM');
  });

  test('importProfile understands links, ssh urls, wg and JSON', () {
    expect(importProfile(a)!.type, ProfileType.v2ray);
    final ssh = importProfile('ssh://root:p%40ss@host.example:2222#My%20SSH')!;
    expect(ssh.type, ProfileType.ssh);
    expect(ssh.s('port'), '2222');
    expect(ssh.s('pass'), 'p@ss');
    expect(ssh.name, 'My SSH');
    expect(importProfile('[Interface]\nPrivateKey=x')!.type, ProfileType.wireguard);
    expect(importProfile('{"outbounds":[]}')!.s('mode'), 'json');
    expect(importProfile('hello world'), isNull);
    expect(importProfile('http://example.com/sub'), isNull);
  });

  test('ids are unique even when created in a tight loop', () {
    final ids = {for (var i = 0; i < 500; i++) newId()};
    expect(ids.length, 500);
  });
}
