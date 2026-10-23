import 'package:flutter_test/flutter_test.dart';
import 'package:vpn/bytebuf.dart';
import 'package:vpn/ssh_tunnel.dart';

void main() {
  test('payload tokens expand', () {
    final out = buildPayload('GET / [protocol][crlf]Host: [host][crlf][crlf]',
        host: 'example.com', port: 22);
    expect(out, ['GET / HTTP/1.1\r\nHost: example.com\r\n\r\n']);
  });

  test('[split] produces separate packets', () {
    final out = buildPayload('GET / [protocol][crlf][crlf][split]CONNECT [host_port] [protocol][crlf][crlf]',
        host: 'h', port: 443);
    expect(out.length, 2);
    expect(out[1], 'CONNECT h:443 HTTP/1.1\r\n\r\n');
  });

  test('[random=] with one option is deterministic', () {
    expect(expandRandomRotate('a.[random=only.com]'), 'a.only.com');
  });

  test('[rotate=] advances once per bumpRotation', () {
    const t = '[rotate=a,b,c]';
    final first = expandRandomRotate(t);
    bumpRotation();
    final second = expandRandomRotate(t);
    expect(first == second, isFalse);
  });

  test('ByteBuf keeps order across appends and takes', () {
    final b = ByteBuf();
    b.add([1, 2, 3]);
    b.add([4, 5]);
    expect(b.length, 5);
    expect(b.take(2), [1, 2]);
    b.add([6]);
    expect(b[0], 3);
    expect(b.take(4), [3, 4, 5, 6]);
    expect(b.isEmpty, isTrue);
  });
}
