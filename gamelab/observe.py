"""Frame identity for the blind-observer check (game-state-repro playbook, box 1.2).

    python -m gamelab.observe <results dir>

Prints every captured frame of the run as `<absolute path>  sha256[:12]  colours=<n>`,
then the observation frame (the last readable one). Exits 1 when the run has no frames
or every frame is blank (<= 64 colours on a 64x36 thumbnail, the runner's shot
threshold). Box 1.2 cannot be ticked then.
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from PIL import Image

BLANK_AT = 64


def colours(png: Path) -> int:
    return len(Image.open(png).convert("RGB").resize((64, 36)).getcolors(64 * 36))


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print(__doc__)
        return 2
    shots = sorted((Path(argv[0]).resolve() / "shots").glob("*.png"), key=lambda p: p.stat().st_mtime)
    readable = []
    for png in shots:
        n = colours(png)
        digest = hashlib.sha256(png.read_bytes()).hexdigest()[:12]
        print(f"{png}  {digest}  colours={n}" + ("  BLANK" if n <= BLANK_AT else ""))
        if n > BLANK_AT:
            readable.append((png, digest))
    if not readable:
        print("no readable frame: " + ("every frame is blank" if shots else "the run captured no frames"))
        return 1
    png, digest = readable[-1]
    print(f"observation frame: {png}  {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
