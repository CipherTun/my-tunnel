"""Rewrites JavaScript-style inline regex flags that Dart does not support.

Dart's RegExp rejects patterns such as  RegExp(r'(?im)^upgrade:\\s*websocket\\s*$')
at runtime with  FormatException: Invalid group.  The flags must be passed as
named arguments instead:  RegExp(r'^upgrade:...$', caseSensitive: false, multiLine: true)

Usage: python3 tools/fix_regex_flags.py [dir ...]   (default: lib)
Only patterns that are invalid in Dart are touched. Anything it cannot rewrite
safely is reported and makes the script exit with status 1.
"""
import re
import sys
from pathlib import Path

CALL = re.compile(
    r"""RegExp\(\s*(?P<raw>r?)(?P<q>["'])\(\?(?P<flags>[imsu]+)\)(?P<body>.*?)(?<!\\)(?P=q)\s*(?P<tail>,[^)]*)?\)""",
    re.S,
)
NAMED = {"i": "caseSensitive: false", "m": "multiLine: true", "s": "dotAll: true", "u": "unicode: true"}
LEFTOVER = re.compile(r"\(\?[imsu]+\)")


def fix_source(src: str):
    changed = []

    def repl(m):
        line_start = src.rfind("\n", 0, m.start()) + 1
        if src[line_start:m.start()].strip().startswith("//"):
            return m.group(0)  # inside a comment
        tail = m.group("tail") or ""
        if tail.strip(", ") and any(k in tail for k in ("caseSensitive", "multiLine", "dotAll", "unicode")):
            return m.group(0)  # already has named flags: leave for a human
        args = ", ".join(NAMED[f] for f in dict.fromkeys(m.group("flags")))
        q = m.group("q")
        changed.append(m.group("flags"))
        return f"RegExp({m.group('raw')}{q}{m.group('body')}{q}, {args}{tail})"

    return CALL.sub(repl, src), changed


def main(argv):
    roots = [Path(a) for a in argv] or [Path("lib")]
    bad = 0
    for root in roots:
        for f in sorted(root.rglob("*.dart")):
            src = f.read_text(encoding="utf-8")
            new, changed = fix_source(src)
            if changed:
                f.write_text(new, encoding="utf-8")
                print(f"fixed {len(changed)} regex(es) in {f}")
            for i, line in enumerate(new.splitlines(), 1):
                if "RegExp" in line and LEFTOVER.search(line) and not line.lstrip().startswith("//"):
                    print(f"WARNING {f}:{i}: inline regex flags remain, fix by hand: {line.strip()}")
                    bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
