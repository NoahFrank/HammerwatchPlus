"""HWR2.exe.log parsing, salvaged from the retired tools/dev_check.py (git show 9d99f0b:tools/dev_check.py).

Formats, as the engine writes them (build 25509441):
  script compile issue   "... ] ERR : scripts/HWP/Foo.as (ln 12, col 3)" with the message on the next line
  runtime error          a line with "Script exception" or "[ERR]"
  mod enabled            "Adding unpacked mod '<id>'" (logged twice: boot + menu level)
The game's own baseline ERR lines are the same with and without mods (docs/RE_NOTES.md),
so a check is scoped to files of the mods under test, never "no ERR at all".
"""
from __future__ import annotations

import re

SCRIPT_ISSUE = re.compile(r"\] (ERR|WARN|WRN|ERROR)\s+: (?P<file>[^ ]+) \(ln (?P<line>\d+), col (?P<col>\d+)\)")
MOD_ADDED = re.compile(r"Adding (packed|unpacked) mod '([^']+)'")
OURS = (r"scripts/HWP/", r"scripts/GameLab/", r"hwp_", r"\[HWP:", r"HammerwatchPlus")


def script_issues(text: str) -> list[dict]:
    out = []
    for m in SCRIPT_ISSUE.finditer(text):
        end = text.find("\n", m.end())
        msg = text[end + 1:text.find("\n", end + 1)].strip() if end >= 0 else ""
        out.append({"kind": m.group(1), "file": m.group("file"), "line": int(m.group("line")),
                    "col": int(m.group("col")), "msg": msg})
    return out


def errors_in(text: str, patterns=OURS) -> list[str]:
    """Compile errors in files matching `patterns`, plus runtime errors mentioning them."""
    ours = re.compile("|".join(patterns))
    bad = [f"{i['kind']} {i['file']}:{i['line']}:{i['col']} {i['msg']}" for i in script_issues(text)
           if i["kind"].startswith("ERR") and ours.search(i["file"])]
    bad += [ln.strip() for ln in text.splitlines()
            if ("Script exception" in ln or "[ERR]" in ln) and ours.search(ln)]
    return bad


def mods_added(text: str) -> list[str]:
    return list(dict.fromkeys(mid for _kind, mid in MOD_ADDED.findall(text)))
