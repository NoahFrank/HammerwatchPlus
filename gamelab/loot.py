"""Is a materials gain one that a loot table can produce? Read from the exported datatable
(gamecode/datatables/tweak/loot/*.sval.json), so the check needs no seeded RNG.

The rules, from gamecode/sdk/hoh2/scripts/Items/LootTable.as:
- every pool rolls once: n = randi(1000), and the first drop whose cumulative chance
  passes n wins. Pools whose chances sum to < 1000 can drop nothing.
- a pool with "conditionals" may be skipped (CheckConditionals); treated as optional.
- ["material", type, min, max] gives randi(max - min) + min of that material. randi's
  upper bound is not measured, so [min, max] (the superset) is accepted.
- every other drop (units, items) adds no materials.

    python -m gamelab.loot tweak/loot/chests.sval cache_bronze gold=154 stone=2
"""
from __future__ import annotations

import itertools
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATATABLES = REPO / "gamecode" / "datatables"


def table(file: str, entry: str) -> dict:
    data = json.loads((DATATABLES / f"{file}.json").read_text(encoding="utf-8"))

    def find(o):
        if isinstance(o, dict):
            if o.get("id") == entry:
                return o
            o = list(o.values())
        if isinstance(o, list):
            for v in o:
                if (hit := find(v)) is not None:
                    return hit
        return None

    hit = find(data)
    if hit is None:
        raise KeyError(f"no loot table {entry!r} in {file}")
    return hit


def pool_options(pool: dict) -> list[tuple | None]:
    """One entry per possible outcome of the pool: (material, lo, hi), or None (no materials)."""
    drops = pool.get("drops", [])
    out, total = [], 0
    for chance, drop in zip(drops[0::2], drops[1::2]):
        total += int(chance)
        if isinstance(drop, list) and drop and drop[0] == "material":
            lo = int(drop[2])
            hi = int(drop[3]) if len(drop) > 3 else lo
            out.append((drop[1], lo, max(lo, hi)))
        else:
            out.append(None)
    if total < 1000 or pool.get("conditionals"):
        out.append(None)
    return sorted(set(out), key=str)


def explain(tbl: dict, gained: dict[str, int]) -> tuple[bool, str]:
    """(achievable, witness or reason) for the per-material gain `gained`."""
    gained = {k: v for k, v in gained.items() if v}
    pools = [pool_options(p) for p in tbl["pools"]]
    for combo in itertools.product(*pools):
        lo, hi = {}, {}
        for opt in combo:
            if opt:
                m, a, b = opt
                lo[m] = lo.get(m, 0) + a
                hi[m] = hi.get(m, 0) + b
        # every material gained was drawn, and every material drawn is within its range
        if set(gained) <= set(lo) and all(lo[m] <= gained.get(m, 0) <= hi[m] for m in lo):
            picks = [f"{o[0]} {o[1]}-{o[2]}" if o else "-" for o in combo]
            return True, "pools: " + ", ".join(picks)
    return False, f"no combination of {len(pools)} pools gives {gained}"


def main(argv=None) -> int:
    a = argv if argv is not None else sys.argv[1:]
    gained = {k: int(v) for k, v in (x.split("=") for x in a[2:])}
    ok, why = explain(table(a[0], a[1]), gained)
    print("achievable" if ok else "NOT achievable", "-", why)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
