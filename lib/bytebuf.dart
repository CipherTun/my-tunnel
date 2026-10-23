import 'dart:typed_data';

/// Append-only byte queue with cheap front removal. Used for stream parsing
/// (WebSocket frames, udpgw packets) instead of List<int>.removeRange loops.
class ByteBuf {
  Uint8List _d = Uint8List(0);
  int _s = 0;

  int get length => _d.length - _s;
  bool get isEmpty => length == 0;

  int operator [](int i) => _d[_s + i];

  void add(List<int> x) {
    if (x.isEmpty) return;
    if (length == 0) {
      _d = x is Uint8List ? x : Uint8List.fromList(x);
      _s = 0;
      return;
    }
    final n = Uint8List(length + x.length);
    n.setRange(0, length, _d, _s);
    n.setRange(length, n.length, x);
    _d = n;
    _s = 0;
  }

  /// Removes and returns the first [n] bytes.
  Uint8List take(int n) {
    assert(n <= length);
    final r = Uint8List.sublistView(_d, _s, _s + n);
    _s += n;
    return r;
  }

  /// Copy of the first [n] bytes without removing them.
  Uint8List peek(int n) => Uint8List.fromList(Uint8List.sublistView(_d, _s, _s + n));

  void clear() {
    _d = Uint8List(0);
    _s = 0;
  }
}
