#!/usr/bin/env python3
"""cite_check.py - every `path.as:line` citation in a doc must land on real source.

    cite_check.py [docs/MECHANICS.md] [--show]

Resolves each `<path>.as:<n>[-<m>][,<k>]` against gamecode/sdk/hoh2/scripts/ (by path,
else by unique file name) and fails on a missing file, a line past the end, or a cited
line that is blank or a lone brace. A citation that lands on code still has to be read
by a human to be the *right* code; --show prints every cited line for that read.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROOT = REPO / "gamecode" / "sdk" / "hoh2" / "scripts"
CITE = re.compile(r"([A-Za-z_/]+\.as):(\d+)(?:-\d+)?((?:,\d+(?:-\d+)?)*)")


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    show = "--show" in argv
    doc = REPO / next((a for a in argv if not a.startswith("--")), "docs/MECHANICS.md")
    by_name: dict[str, list[Path]] = {}
    for p in ROOT.rglob("*.as"):
        by_name.setdefault(p.name, []).append(p)
    bad, n = [], 0
    for m in CITE.finditer(doc.read_text(encoding="utf-8")):
        f, first, rest = m.groups()
        p = ROOT / f
        if not p.is_file():
            cands = by_name.get(Path(f).name, [])
            p = cands[0] if len(cands) == 1 else None
        if p is None:
            bad.append(f"{f}: no such file (or ambiguous name)")
            continue
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        for k in [int(first)] + [int(x.split("-")[0]) for x in rest.strip(",").split(",") if x]:
            n += 1
            text = lines[k - 1].strip() if k <= len(lines) else None
            if text is None or text in ("", "{", "}"):
                bad.append(f"{f}:{k}: {'past end of file' if text is None else 'blank/brace line'}")
            elif show:
                print(f"{f}:{k}: {text[:100]}")
    for b in bad:
        print("BAD", b)
    print(f"{doc.relative_to(REPO)}: {n} cited lines, {len(bad)} bad")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
