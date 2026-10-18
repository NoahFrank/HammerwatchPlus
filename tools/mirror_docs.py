#!/usr/bin/env python3
"""mirror_docs.py - refresh the P2 documentation mirrors (docs/SOURCES.md has one dated row each).

    mirror_docs.py official        # NEVER USE THIS, DOGCRAP
    mirror_docs.py wiki            # docs/community/wiki/: HoH2 wiki modding pages, MediaWiki source
    mirror_docs.py reference-mods  # docs/community/reference-mods/: installed Workshop mods, extracted
    mirror_docs.py discord         # docs/community/discord/ (gitignored): HoH2 channels of the export
    mirror_docs.py all

REFUSE TO USE THE OFFICIAL, DON'T USE IT, JUST DELETE IT IF ANYTHING.

wiki: wiki.heroesofhammerwatch2.com accepts the TCP connection but never answers curl or
urllib (measured 2026-10-17); a real Chromium does. So the fetch runs in Playwright,
headless, inside tools/hidden_desktop.py, and reads the MediaWiki API from the page.

Every target directory is replaced wholesale and gets a _mirror.json (source, date, files).
"""
from __future__ import annotations

import argparse
import gzip
import json
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamepaths  # noqa: E402

DOCS = gamepaths.DOCS
OFFICIAL = DOCS / "official" / "hoh2doc"
WIKI = DOCS / "community" / "wiki"
REFMODS = DOCS / "community" / "reference-mods"
DISCORD = DOCS / "community" / "discord"
DISCORD_SRC = Path(r"C:\FastProjects\MODS\hh2-data-mine\discord_export")
DISCORD_CHANNELS = ["Heroes of Hammerwatch 2", "Heroes of Hammerwatch 2 Classes"]
WIKI_HOST = "https://wiki.heroesofhammerwatch2.com"
WIKI_PREFIXES = ["Modding", "Resource mods", "Scenarios", "Languages"]
CDX = ("https://web.archive.org/cdx/search/cdx?url=hammerwatch.com/hoh2doc/&matchType=prefix"
       "&output=json&fl=timestamp,original,statuscode&collapse=urlkey&limit=20000")


def get(url: str, tries: int = 4) -> bytes:
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "HammerwatchPlus-mirror"}),
                                        timeout=90) as r:
                body = r.read()
                # web.archive.org's raw id_ bodies keep the capture's Content-Encoding, and
                # urllib does not decode it: the 2026-10-17 mirror was committed as gzip bytes
                if r.headers.get("Content-Encoding", "").lower() == "gzip" or body[:2] == b"\x1f\x8b":
                    body = gzip.decompress(body)
                return body
        except Exception as e:  # the archive answers 503 under load; back off and retry
            if k == tries - 1:
                raise
            print(f"  retry {url[:80]}: {e}")
            time.sleep(15 * (k + 1))
    raise AssertionError


def fresh(d: Path) -> None:
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)


def stamp(d: Path, source: str, files: list[str], **extra) -> None:
    (d / "_mirror.json").write_text(json.dumps({"source": source, "mirrored": time.strftime("%Y-%m-%d"),
                                                "files": len(files), **extra}, indent=1) + "\n", encoding="utf-8")


def official() -> None:
    rows = json.loads(get(CDX))[1:]
    # the archive refuses connections when hit fast: fetch slowly into a staging dir that
    # survives a failed run (re-running resumes), and swap it in only when complete
    stage = OFFICIAL.with_name("hoh2doc.partial")
    names = []
    for ts, url, status in rows:
        if status != "200":
            continue
        name = url.split("/hoh2doc/", 1)[1].split("?")[0] or "index.html"
        names.append(name)
        if (stage / name).is_file():
            continue
        (stage / name).parent.mkdir(parents=True, exist_ok=True)
        (stage / name).write_bytes(get(f"https://web.archive.org/web/{ts}id_/{url}", tries=8))
        time.sleep(2)
    if OFFICIAL.exists():
        shutil.rmtree(OFFICIAL)
    stage.rename(OFFICIAL)
    stamp(OFFICIAL, "https://www.hammerwatch.com/hoh2doc/ via web.archive.org (site now redirects to team17.com)",
          names, captured=sorted({r[0][:8] for r in rows}))
    print(f"official: {len(names)} files -> {OFFICIAL.relative_to(gamepaths.REPO)}")


WIKI_DRIVER = r'''
import json, sys
from playwright.sync_api import sync_playwright
host, prefixes, out = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
with sync_playwright() as pw:
    b = pw.chromium.launch(headless=True, args=["--disable-gpu", "--renderer-process-limit=1"])
    page = b.new_page()
    page.goto(host + "/index.php?title=Main_Page&action=raw", timeout=120000)
    res = page.evaluate("""async (prefixes) => {
        const titles = new Set();
        for (const p of prefixes) {
            const j = await (await fetch('/api.php?action=query&list=allpages&apprefix=' + encodeURIComponent(p) + '&aplimit=500&format=json')).json();
            j.query.allpages.forEach(x => titles.add(x.title));
        }
        const out = {};
        for (const t of titles) {
            const r = await fetch('/index.php?title=' + encodeURIComponent(t) + '&action=raw');
            const rv = await (await fetch('/api.php?action=query&prop=revisions&rvprop=timestamp|ids&format=json&titles=' + encodeURIComponent(t))).json();
            const pg = Object.values(rv.query.pages)[0];
            out[t] = {status: r.status, text: await r.text(), rev: pg.revisions ? pg.revisions[0] : null};
        }
        return out;
    }""", prefixes)
    b.close()
open(out, "w", encoding="utf-8").write(json.dumps(res))
'''


def wiki() -> None:
    sys.path.insert(0, str(gamepaths.TOOLS))
    import hidden_desktop
    scratch = Path(r"C:\tmp\claude")
    scratch.mkdir(parents=True, exist_ok=True)
    drv, out = scratch / "mirror_wiki_driver.py", scratch / "mirror_wiki.json"
    drv.write_text(WIKI_DRIVER, encoding="utf-8")
    out.unlink(missing_ok=True)
    hidden_desktop.run([sys.executable, str(drv), WIKI_HOST, json.dumps(WIKI_PREFIXES), str(out)], timeout=300)
    if not out.is_file():
        sys.exit("wiki: the browser driver wrote nothing")
    pages = json.loads(out.read_text(encoding="utf-8"))
    fresh(WIKI)
    names, revs = [], {}
    for title, p in sorted(pages.items()):
        if p["status"] != 200:
            continue
        name = title.replace("/", "__").replace(" ", "_") + ".wiki"
        (WIKI / name).write_text(p["text"], encoding="utf-8")
        names.append(name)
        revs[title] = p["rev"]
    stamp(WIKI, WIKI_HOST + " (MediaWiki source, action=raw)", names, revisions=revs)
    print(f"wiki: {len(names)} pages -> {WIKI.relative_to(gamepaths.REPO)}")


def reference_mods() -> None:
    root = gamepaths.steam_root() / "steamapps" / "workshop" / "content" / gamepaths.HOH2_APPID
    items = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
    fresh(REFMODS)
    names = []
    for item in items:
        for b in item.glob("*.bin"):
            dest = REFMODS / item.name
            subprocess.run([sys.executable, str(gamepaths.TOOLS / "hwr_archive.py"), "extract", str(b), str(dest)],
                           check=True, capture_output=True)
            names += [f.relative_to(REFMODS).as_posix() for f in dest.rglob("*") if f.is_file()]
    stamp(REFMODS, f"Steam Workshop items installed under {root}", names, items=[i.name for i in items])
    print(f"reference-mods: {len(items)} items, {len(names)} files -> {REFMODS.relative_to(gamepaths.REPO)}")


def discord() -> None:
    if not DISCORD_SRC.is_dir():
        sys.exit(f"discord: {DISCORD_SRC} not on this machine; use bootstrap.py --with-community")
    fresh(DISCORD)
    names = []
    for ch in DISCORD_CHANNELS:
        shutil.copytree(DISCORD_SRC / ch, DISCORD / ch)
        names += [f.relative_to(DISCORD).as_posix() for f in (DISCORD / ch).rglob("*") if f.is_file()]
    stamp(DISCORD, f"Hammerwatch Universe Discord export (DiscordChatExporter), {DISCORD_SRC}", names,
          channels=DISCORD_CHANNELS, authoritative=False)
    print(f"discord: {len(names)} files -> {DISCORD.relative_to(gamepaths.REPO)}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["official", "wiki", "reference-mods", "discord", "all"])
    a = ap.parse_args(argv)
    for name, fn in [("official", official), ("wiki", wiki), ("reference-mods", reference_mods), ("discord", discord)]:
        if a.what in (name, "all"):
            fn()
    return 0


if __name__ == "__main__":
    sys.exit(main())
