import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Dart's RegExp has no inline flags: a pattern starting with an inline-flag group compiles in the
/// editor but throws "FormatException: Invalid group" the first time it runs on the phone.
void main() {
  test('no RegExp in lib/ uses inline flags like (?i) or (?m)', () {
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('RegExp') && RegExp(r'\(\?[imsu]+\)').hasMatch(lines[i])) {
          bad.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(bad, isEmpty, reason: 'use RegExp(..., caseSensitive: false, multiLine: true) instead');
  });

  test('every RegExp pattern in lib/ compiles', () {
    // Catches other pattern syntax Dart rejects, e.g. possessive quantifiers.
    final src = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync())
        .join('\n');
    final lit = RegExp(r'''RegExp\(\s*r?(["'])(.*?)(?<!\\)\1''');
    for (final m in lit.allMatches(src)) {
      final body = m.group(2)!;
      if (body.contains(r'$')) continue; // interpolated, cannot be checked statically
      expect(() => RegExp(body), returnsNormally, reason: body);
    }
  });
}
